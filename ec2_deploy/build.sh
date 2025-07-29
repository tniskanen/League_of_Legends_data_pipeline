#!/bin/bash
set -e

# Enable debug logging if DEBUG=true
if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

echo "🚀 Starting Docker image build and push process..."

# Validate required environment variables
REQUIRED_VARS=(AWS_ACCOUNT_ID AWS_REGION ECR_REPOSITORY_EC2)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "❌ Error: Environment variable $var is not set"
    echo "Available environment variables:"
    env | grep -E '^(AWS_|ECR_|REGION|REPO_)' | sort
    exit 1
  fi
done

# Set image variables
IMAGE_NAME="${ECR_REPOSITORY_EC2}:latest"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY_EC2}"

echo "🔍 Configuration:"
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
MAX_RETRIES=3
retry_count=0

while [ $retry_count -lt $MAX_RETRIES ]; do
  if aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"; then
    echo "✅ Logged in to ECR"
    break
  else
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $MAX_RETRIES ]; then
      echo "⚠️ Login failed. Retrying... ($retry_count/$MAX_RETRIES)"
      sleep 5
    else
      echo "❌ Failed to login to ECR after $MAX_RETRIES attempts"
      exit 1
    fi
  fi
done

# Set build context and Dockerfile
DOCKER_CONTEXT="${DOCKER_CONTEXT:-.}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-docker/ec2}"

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