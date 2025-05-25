#!/bin/bash

# Enhanced script to build and push Docker images to AWS ECR
# Exit on any error
set -e

# Enable command tracing for verbose output if DEBUG is set
if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

echo "🚀 Starting Docker image build and push process..."

# Load environment variables from variables.env (checking both current and parent directory)
if [ -f variables.env ]; then
  export $(grep -v '^#' variables.env | xargs)
  echo "✅ Environment variables loaded from variables.env"
elif [ -f ../variables.env ]; then
  export $(grep -v '^#' ../variables.env | xargs)
  echo "✅ Environment variables loaded from ../variables.env"
else
  echo "❌ variables.env file not found in current or parent directory. Please create it and add required variables."
  exit 1
fi

# Ensure necessary environment variables are set
REQUIRED_VARS=(AWS_ACCOUNT_ID REGION REPO_NAME)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "❌ Error: $var is not set in variables.env"
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
  if aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${ECR_URI%:*}"; then
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
DOCKERFILE_PATH="${DOCKERFILE_PATH:-docker/ec2}"

# Print details about what we're building
echo "🔍 Building using:"
echo "  - Dockerfile: ${DOCKERFILE_PATH}"
echo "  - Context: ${DOCKER_CONTEXT}"
if [ ! -f "${DOCKERFILE_PATH}" ]; then
  echo "❌ ERROR: Dockerfile not found at ${DOCKERFILE_PATH}"
  exit 1
fi

# Build Docker image with build arguments if provided
echo "🔨 Building Docker image..."
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
echo "✅ Docker image successfully built and pushed to: ${ECR_URI}"

# Optionally clean up local images to free space
if [ "${CLEANUP:-false}" = "true" ]; then
  echo "🧹 Cleaning up local Docker images..."
  docker image prune -f
fi