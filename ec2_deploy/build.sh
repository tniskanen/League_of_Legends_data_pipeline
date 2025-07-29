#!/bin/bash
set -e

# Enable debug logging if DEBUG=true
if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

echo "🚀 Starting Docker image build and push process..."

# Validate required environment variables
REQUIRED_VARS=(ECR_REGISTRY AWS_REGION ECR_REPOSITORY_EC2)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "❌ Error: Environment variable $var is not set"
    echo "Available environment variables:"
    env | grep -E '^(AWS_|ECR_|REGION|REPO_)' | sort
    exit 1
  fi
done
  
# Extract AWS Account ID from ECR Registry URI if needed
if [[ "${ECR_REGISTRY}" =~ ^([0-9]{12})\.dkr\.ecr\.([^.]+)\.amazonaws\.com$ ]]; then
  AWS_ACCOUNT_ID="${BASH_REMATCH[1]}"
  EXTRACTED_REGION="${BASH_REMATCH[2]}"
  echo "✅ Extracted from ECR_REGISTRY:"
  echo "  - AWS Account ID: ${AWS_ACCOUNT_ID}"
  echo "  - Registry Region: ${EXTRACTED_REGION}"
  
  # Use the region from ECR registry if AWS_REGION doesn't match
  if [ "${AWS_REGION}" != "${EXTRACTED_REGION}" ]; then
    echo "⚠️ Region mismatch detected:"
    echo "  - AWS_REGION: ${AWS_REGION}"
    echo "  - ECR Registry Region: ${EXTRACTED_REGION}"
    echo "  - Using ECR Registry Region: ${EXTRACTED_REGION}"
    AWS_REGION="${EXTRACTED_REGION}"
  fi
else
  echo "❌ Error: ECR_REGISTRY format is invalid: ${ECR_REGISTRY}"
  echo "Expected format: ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com"
  exit 1
fi

# Set image variables
IMAGE_NAME="${ECR_REPOSITORY_EC2}:latest"
ECR_URI="${ECR_REGISTRY}/${ECR_REPOSITORY_EC2}:latest"

echo "🔍 Configuration:"
echo "  - ECR Registry: ${ECR_REGISTRY}"
echo "  - AWS Account ID: ${AWS_ACCOUNT_ID}"
echo "  - AWS Region: ${AWS_REGION}"
echo "  - ECR Repository: ${ECR_REPOSITORY_EC2}"
echo "  - ECR URI: ${ECR_URI}"
echo "  - Image Name: ${IMAGE_NAME}"

# Check prerequisites
if ! command -v aws &> /dev/null; then
  echo "❌ AWS CLI is not installed"
  exit 1
fi

if ! command -v docker &> /dev/null; then
  echo "❌ Docker is not installed"
  exit 1
fi

if ! docker info &> /dev/null; then
  echo "❌ Docker is not running"
  exit 1
fi

# Ensure ECR repo exists
echo "🔍 Checking if ECR repository exists..."
if ! aws ecr describe-repositories --repository-names "${ECR_REPOSITORY_EC2}" --region "${AWS_REGION}" &> /dev/null; then
  echo "🔨 Creating ECR repository: ${ECR_REPOSITORY_EC2}"
  aws ecr create-repository --repository-name "${ECR_REPOSITORY_EC2}" --region "${AWS_REGION}"
else
  echo "✅ ECR repository exists: ${ECR_REPOSITORY_EC2}"
fi

# Login to ECR
echo "🔑 Logging into ECR..."
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
echo "🔍 ECR Registry: ${ECR_REGISTRY}"

MAX_RETRIES=3
retry_count=0

while [ $retry_count -lt $MAX_RETRIES ]; do
  echo "🔐 Attempting ECR login (attempt $((retry_count + 1))/$MAX_RETRIES)..."
  
  # Method 1: Standard ECR login
  if LOGIN_TOKEN=$(aws ecr get-login-password --region "${AWS_REGION}" 2>&1) && \
     echo "${LOGIN_TOKEN}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}" 2>&1; then
    echo "✅ Successfully logged in to ECR using standard method"
    break
  else
    echo "⚠️ Standard ECR login failed, trying alternative method..."
    
    # Method 2: Using get-authorization-token (legacy but sometimes more reliable)
    if aws ecr get-authorization-token --region "${AWS_REGION}" --output text --query 'authorizationData[].authorizationToken' | base64 -d | cut -d: -f2 | docker login --username AWS --password-stdin "${ECR_REGISTRY}" 2>&1; then
      echo "✅ Successfully logged in to ECR using alternative method"
      break
    else
      retry_count=$((retry_count + 1))
      if [ $retry_count -lt $MAX_RETRIES ]; then
        echo "⚠️ Both ECR login methods failed. Checking connectivity and retrying..."
      
      # Debug information
      echo "🔍 Debugging ECR connectivity:"
      echo "  - AWS Region: ${AWS_REGION}"
      echo "  - AWS Account ID: ${AWS_ACCOUNT_ID}"
      echo "  - ECR Registry: ${ECR_REGISTRY}"
      
      # Test AWS CLI connectivity
      if aws sts get-caller-identity --region "${AWS_REGION}" >/dev/null 2>&1; then
        echo "  ✅ AWS CLI credentials are working"
      else
        echo "  ❌ AWS CLI credentials issue"
      fi
      
      # Test ECR registry connectivity
      if nslookup "${ECR_REGISTRY}" >/dev/null 2>&1; then
        echo "  ✅ ECR registry DNS resolution working"
      else
        echo "  ❌ ECR registry DNS resolution failed"
        echo "  🔄 Trying alternative DNS resolution..."
        
        # Try with different DNS approach
        if dig "${ECR_REGISTRY}" >/dev/null 2>&1; then
          echo "  ✅ Alternative DNS resolution working"
        else
          echo "  ❌ DNS issues detected"
        fi
      fi
      
      # Try direct AWS ECR get-authorization-token as alternative
      echo "  🔄 Trying alternative ECR authentication method..."
      if aws ecr get-authorization-token --region "${AWS_REGION}" >/dev/null 2>&1; then
        echo "  ✅ ECR authorization token retrieval working"
      else
        echo "  ❌ ECR authorization token retrieval failed"
      fi
      
      sleep 5
    else
      echo "❌ Failed to login to ECR after $MAX_RETRIES attempts"
      echo "🔍 Final debug information:"
      echo "  - Region: ${AWS_REGION}"
      echo "  - Registry: ${ECR_REGISTRY}"
      echo "  - Account ID: ${AWS_ACCOUNT_ID}"
      
      # Try to get more specific error information
      echo "🔍 Testing AWS ECR describe-repositories..."
      aws ecr describe-repositories --repository-names "${ECR_REPOSITORY_EC2}" --region "${AWS_REGION}" || echo "ECR repository access failed"
      
      exit 1
    fi
  fi
done

# Set build context and Dockerfile
DOCKER_CONTEXT="${DOCKER_CONTEXT:-.}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-docker/ec2/Dockerfile}"

echo "🔍 Building with:"
echo "  - Dockerfile: ${DOCKERFILE_PATH}"
echo "  - Context: ${DOCKER_CONTEXT}"

# Check if Dockerfile exists
if [ ! -f "${DOCKERFILE_PATH}" ]; then
  # Try alternative paths
  if [ -f "docker/ec2" ]; then
    DOCKERFILE_PATH="docker/ec2"
  elif [ -f "Dockerfile" ]; then
    DOCKERFILE_PATH="Dockerfile"
  else
    echo "❌ Dockerfile not found at ${DOCKERFILE_PATH}"
    echo "Available files in docker directory:"
    ls -la docker/ || echo "docker/ directory not found"
    exit 1
  fi
fi

echo "✅ Using Dockerfile: ${DOCKERFILE_PATH}"

# Build the image
echo "🔨 Building Docker image..."
build_cmd="docker build -t \"${IMAGE_NAME}\""

# Add build args if provided
if [ -n "${BUILD_ARGS}" ]; then
  echo "🔧 Adding build arguments: ${BUILD_ARGS}"
  for arg in ${BUILD_ARGS}; do
    build_cmd+=" --build-arg ${arg}"
  done
fi

build_cmd+=" -f ${DOCKERFILE_PATH} ${DOCKER_CONTEXT}"

echo "Running: $build_cmd"
eval "$build_cmd"

# Tag for ECR
echo "🏷️ Tagging image for ECR: ${ECR_URI}"
docker tag "${IMAGE_NAME}" "${ECR_URI}"

# Push to ECR with retry logic
echo "📤 Pushing image to ECR..."
retry_count=0
while [ $retry_count -lt $MAX_RETRIES ]; do
  if docker push "${ECR_URI}"; then
    echo "✅ Successfully pushed image to ECR"
    break
  else
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $MAX_RETRIES ]; then
      echo "⚠️ Push failed. Retrying... ($retry_count/$MAX_RETRIES)"
      sleep 5
    else
      echo "❌ Failed to push image after $MAX_RETRIES attempts"
      exit 1
    fi
  fi
done

# Optional cleanup
if [ "${CLEANUP:-false}" = "true" ]; then
  echo "🧹 Cleaning up local Docker images..."
  docker image prune -f
  # Remove the local tagged images
  docker rmi "${IMAGE_NAME}" "${ECR_URI}" || true
fi

echo "✅ Build and push complete!"
echo "📋 Summary:"
echo "  - Image: ${ECR_URI}"
echo "  - Status: Successfully pushed to ECR"