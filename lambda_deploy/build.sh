#!/bin/bash

# Enhanced script to build and push Lambda Docker images to AWS ECR
# Exit on any error
set -e

# Enable command tracing for verbose output if DEBUG is set
if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

echo "🚀 Starting Lambda Docker image build and push process..."

# Load environment variables from lambda.env (safer method)
load_env_file() {
  local env_file="$1"
  if [ -f "$env_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      # Skip empty lines and comments
      if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      # Remove leading/trailing whitespace and export
      line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        export "$line"
      fi
    done < "$env_file"
    return 0
  fi
  return 1
}

# FIXED: Actually load the environment file
ENV_FILE="${ENV_FILE:-lambda.env}"
if ! load_env_file "$ENV_FILE"; then
  echo "❌ Error: Environment file '$ENV_FILE' not found. Please create it with required variables."
  exit 1
fi

echo "✅ Loaded environment variables from $ENV_FILE"

# Ensure necessary environment variables are set
REQUIRED_VARS=(AWS_ACCOUNT_ID REGION REPO_NAME_LAMBDA)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "❌ Error: $var is not set in $ENV_FILE"
    exit 1
  fi
done

# Set up image names and ECR URI
IMAGE_NAME="${REPO_NAME_LAMBDA}:latest"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME_LAMBDA}"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
  echo "❌ AWS CLI is not installed. Please install it first."
  exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
  echo "❌ Docker is not running. Please start Docker and try again."
  exit 1
fi

# NEW: Aggressive cleanup to avoid manifest issues
echo "🧹 Performing aggressive cleanup to avoid manifest issues..."

# Clean all local Docker images related to this project
echo "🗑️ Removing all local images for ${REPO_NAME_LAMBDA}..."
docker images --filter "reference=${REPO_NAME_LAMBDA}" -q | xargs docker rmi -f 2>/dev/null || true
docker images --filter "reference=${ECR_URI}" -q | xargs docker rmi -f 2>/dev/null || true

# Clean Docker buildx cache and builder instances
echo "🧹 Cleaning Docker buildx cache..."
docker buildx prune -f &> /dev/null || true
docker buildx ls | grep -v "default" | awk '{print $1}' | xargs -r docker buildx rm 2>/dev/null || true

# Clean Docker system completely
echo "🧹 Cleaning Docker system completely..."
docker system prune -a -f &> /dev/null || true

# Remove and recreate ECR repository to ensure clean state
if aws ecr describe-repositories --repository-names "${REPO_NAME_LAMBDA}" --region "${REGION}" &> /dev/null; then
  echo "🗑️ Deleting entire ECR repository to ensure clean state..."
  aws ecr delete-repository --repository-name "${REPO_NAME_LAMBDA}" --region "${REGION}" --force &> /dev/null || true
  sleep 2
fi

echo "🔨 Creating fresh ECR repository: ${REPO_NAME_LAMBDA}"
aws ecr create-repository --repository-name "${REPO_NAME_LAMBDA}" --region "${REGION}"

# Log in to ECR with retry logic
echo "🔑 Logging into ECR..."
MAX_RETRIES=3
retry_count=0

while [ $retry_count -lt $MAX_RETRIES ]; do
  if aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${ECR_URI%%/*}"; then
    echo "✅ Successfully logged into ECR"
    break
  else
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $MAX_RETRIES ]; then
      echo "⚠️ Failed to log in to ECR. Retrying in 5 seconds... (Attempt $retry_count of $MAX_RETRIES)"
      sleep 5
    else
      echo "❌ Failed to log in to ECR after $MAX_RETRIES attempts"
      exit 1
    fi
  fi
done

# Set Docker build path and Dockerfile location
DOCKER_CONTEXT="${DOCKER_CONTEXT:-.}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-docker/lambda}"

# Print details about what we're building
echo "🔍 Building Lambda container using:"
echo "  - Dockerfile: ${DOCKERFILE_PATH}"
echo "  - Context: ${DOCKER_CONTEXT}"
if [ ! -f "${DOCKERFILE_PATH}" ]; then
  echo "❌ ERROR: Dockerfile not found at ${DOCKERFILE_PATH}"
  exit 1
fi

# ENHANCED: Use standard docker build (not buildx) with explicit settings
echo "🔨 Building Lambda Docker image with standard docker build (avoiding buildx)..."

# Disable buildx to use standard docker build
export DOCKER_BUILDKIT=0

# Build with explicit platform and no cache
docker build \
  --platform linux/amd64 \
  --no-cache \
  --pull \
  -t "${IMAGE_NAME}" \
  -f "${DOCKERFILE_PATH}" \
  ${BUILD_ARGS:+$(echo "$BUILD_ARGS" | sed 's/\([^=]*=[^[:space:]]*\)/--build-arg \1/g')} \
  "${DOCKER_CONTEXT}"

# Re-enable buildkit for other operations
export DOCKER_BUILDKIT=1

# NEW: Verify the image has correct platform before proceeding
echo "🔍 Verifying image platform..."
image_platform=$(docker inspect "${IMAGE_NAME}" --format '{{.Architecture}}/{{.Os}}')
if [ "$image_platform" != "amd64/linux" ]; then
  echo "❌ ERROR: Image platform is $image_platform but should be amd64/linux"
  exit 1
fi
echo "✅ Image platform verified: $image_platform"

# Verify Lambda compatibility by running a quick test
echo "🧪 Testing Lambda container locally..."
container_id=$(docker run -d -p 9000:8080 --platform linux/amd64 "${IMAGE_NAME}")
sleep 5

# Test the Lambda function endpoint
if curl -s -f "http://localhost:9000/2015-03-31/functions/function/invocations" -d '{}' --max-time 10 &>/dev/null; then
  echo "✅ Lambda container test successful"
else
  echo "⚠️ Lambda container test failed - checking container logs..."
  docker logs "$container_id"
fi

# Stop and remove test container
docker stop "$container_id" &>/dev/null || true
docker rm "$container_id" &>/dev/null || true

# Tag image for ECR
echo "🏷️ Tagging image as: ${ECR_URI}"
docker tag "${IMAGE_NAME}" "${ECR_URI}"

# NEW: Verify manifest before pushing
echo "🔍 Verifying local image manifest..."
local_manifest=$(docker inspect "${ECR_URI}" --format '{{.Architecture}}/{{.Os}}')
if [ "$local_manifest" != "amd64/linux" ]; then
  echo "❌ ERROR: Tagged image has wrong platform: $local_manifest"
  exit 1
fi
echo "✅ Local image manifest verified: $local_manifest"

# ENHANCED: Use direct docker push without manifest manipulation
echo "📤 Pushing image to ECR using direct push..."

# Push using docker push (not buildx)
export DOCKER_BUILDKIT=0
retry_count=0

while [ $retry_count -lt $MAX_RETRIES ]; do
  if docker push "${ECR_URI}"; then
    echo "✅ Successfully pushed image to ECR"
    break
  else
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $MAX_RETRIES ]; then
      echo "⚠️ Failed to push to ECR. Retrying in 5 seconds... (Attempt $retry_count of $MAX_RETRIES)"
      sleep 5
    else
      echo "❌ Failed to push to ECR after $MAX_RETRIES attempts"
      exit 1
    fi
  fi
done

# Re-enable buildkit
export DOCKER_BUILDKIT=1

# NEW: Verify the pushed image manifest in ECR and fix platform info if needed
echo "🔍 Verifying pushed image manifest in ECR..."
sleep 3  # Give ECR a moment to process the push

# Check if manifest has platform information
ecr_manifest=$(docker manifest inspect "${ECR_URI}" 2>/dev/null || echo "failed")

if [ "$ecr_manifest" = "failed" ]; then
  echo "❌ ERROR: Could not inspect ECR manifest"
  exit 1
fi

# Check if manifest is missing platform information (single manifest without platform)
if echo "$ecr_manifest" | grep -q '"mediaType": "application/vnd.oci.image.manifest.v1+json"' && ! echo "$ecr_manifest" | grep -q '"platform"'; then
  echo "⚠️ WARNING: Manifest is missing platform information. This is likely the cause of the Lambda error."
  echo "🔄 Attempting to fix by re-pushing with explicit platform..."
  
  # Pull the image back locally to re-tag with platform
  docker pull "${ECR_URI}"
  
  # Re-tag and push with explicit platform using buildx
  export DOCKER_BUILDKIT=1
  echo "🔄 Re-pushing with explicit platform information..."
  
  # Create a new buildx builder for this specific task
  docker buildx create --name lambda-builder --use --platform linux/amd64 2>/dev/null || true
  
  # Push with explicit platform
  docker buildx imagetools create --tag "${ECR_URI}" "${ECR_URI}" --platform linux/amd64
  
  # Clean up the builder
  docker buildx rm lambda-builder 2>/dev/null || true
  
  # Verify the fix
  sleep 3
  ecr_manifest=$(docker manifest inspect "${ECR_URI}" 2>/dev/null || echo "failed")
  
  if echo "$ecr_manifest" | grep -q '"platform"'; then
    echo "✅ Successfully added platform information to manifest"
  else
    echo "❌ Failed to add platform information. Trying alternative approach..."
    
    # Alternative: rebuild and push with buildx from scratch
    echo "🔄 Rebuilding with buildx for proper platform manifest..."
    
    # Create buildx builder
    docker buildx create --name lambda-builder --use --platform linux/amd64 2>/dev/null || true
    
    # Build and push with buildx
    cd "${DOCKER_CONTEXT}"
    docker buildx build \
      --platform linux/amd64 \
      --push \
      --no-cache \
      --tag "${ECR_URI}" \
      -f "${DOCKERFILE_PATH}" \
      ${BUILD_ARGS:+$(echo "$BUILD_ARGS" | sed 's/\([^=]*=[^[:space:]]*\)/--build-arg \1/g')} \
      .
    
    # Clean up builder
    docker buildx rm lambda-builder 2>/dev/null || true
    
    # Final verification
    sleep 3
    ecr_manifest=$(docker manifest inspect "${ECR_URI}" 2>/dev/null || echo "failed")
  fi
fi

# Final manifest validation
if echo "$ecr_manifest" | grep -q '"architecture": "unknown"'; then
  echo "❌ ERROR: ECR manifest still contains unknown architecture!"
  echo "Manifest contents:"
  echo "$ecr_manifest"
  exit 1
fi

if echo "$ecr_manifest" | grep -q '"platform"' || echo "$ecr_manifest" | grep -q '"architecture": "amd64"'; then
  echo "✅ ECR manifest verified - proper platform information found"
else
  echo "⚠️ WARNING: Manifest may still be missing platform information"
  echo "This could cause Lambda deployment issues"
fi

# Verify the image was pushed successfully
echo "🔍 Verifying image in ECR..."
if aws ecr describe-images --repository-name "${REPO_NAME_LAMBDA}" --region "${REGION}" --image-ids imageTag=latest &>/dev/null; then
  echo "✅ Image verified in ECR"
else
  echo "❌ Image not found in ECR"
  exit 1
fi

# Print success message with full ECR URI
echo "✅ Lambda Docker image successfully built and pushed to: ${ECR_URI}"
echo "🎯 Image is ready for Lambda deployment with clean manifest"

# Optionally clean up local images to free space
if [ "${CLEANUP:-false}" = "true" ]; then
  echo "🧹 Cleaning up local Docker images..."
  docker image prune -f
fi