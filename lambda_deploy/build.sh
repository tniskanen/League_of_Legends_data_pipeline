#!/bin/bash

# Enhanced script to build and push Lambda Docker images to AWS ECR
# Exit on any error
set -e

# Enable command tracing for verbose output if DEBUG is set
if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

echo "🚀 Starting Lambda Docker image build and push process..."

# Load environment variables from variables.env (safer method)
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
ENV_FILE="${ENV_FILE:-variables.env}"
if ! load_env_file "$ENV_FILE"; then
  echo "❌ Error: Environment file '$ENV_FILE' not found. Please create it with required variables."
  exit 1
fi

echo "✅ Loaded environment variables from $ENV_FILE"

# Ensure necessary environment variables are set
REQUIRED_VARS=(AWS_ACCOUNT_ID REGION REPO_NAME)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "❌ Error: $var is not set in $ENV_FILE"
    exit 1
  fi
done

# Set up image names and ECR URI
IMAGE_NAME="${REPO_NAME}:latest"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

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

# Check if the ECR repository exists, create if it doesn't
echo "🔍 Checking if ECR repository exists..."
if ! aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${REGION}" &> /dev/null; then
  echo "🔨 Creating ECR repository: ${REPO_NAME}"
  aws ecr create-repository --repository-name "${REPO_NAME}" --region "${REGION}"
fi

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

# Build Docker image with build arguments if provided
echo "🔨 Building Lambda Docker image..."
build_cmd="docker build -t \"${IMAGE_NAME}\" -f ${DOCKERFILE_PATH} ${DOCKER_CONTEXT}"

# Add build arguments if specified in variables.env
# Format in variables.env: BUILD_ARGS="ARG1=value1 ARG2=value2"
if [ -n "${BUILD_ARGS}" ]; then
  for arg in ${BUILD_ARGS}; do
    build_cmd="${build_cmd} --build-arg ${arg}"
  done
fi

# Execute the build command
eval $build_cmd

# Verify Lambda compatibility by running a quick test
echo "🧪 Testing Lambda container locally..."
container_id=$(docker run -d -p 9000:8080 "${IMAGE_NAME}")
sleep 3

# Test the Lambda function endpoint
if curl -s -f "http://localhost:9000/2015-03-31/functions/function/invocations" -d '{}' &>/dev/null; then
  echo "✅ Lambda container test successful"
else
  echo "⚠️ Lambda container test failed - container may not be compatible with Lambda runtime"
fi

# Stop and remove test container
docker stop "$container_id" &>/dev/null
docker rm "$container_id" &>/dev/null

# Tag image for ECR
echo "🏷️ Tagging image as: ${ECR_URI}"
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
      echo "⚠️ Failed to push to ECR. Retrying in 5 seconds... (Attempt $retry_count of $MAX_RETRIES)"
      sleep 5
    else
      echo "❌ Failed to push to ECR after $MAX_RETRIES attempts"
      exit 1
    fi
  fi
done

# Print success message with full ECR URI
echo "✅ Lambda Docker image successfully built and pushed to: ${ECR_URI}"

# Optionally clean up local images to free space
if [ "${CLEANUP:-false}" = "true" ]; then
  echo "🧹 Cleaning up local Docker images..."
  docker image prune -f
fi