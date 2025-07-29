#!/bin/bash

# Enhanced script to deploy Docker images to EC2 instances
# Exit on any error
set -e

# Enable command tracing for verbose output if DEBUG is set
if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

echo "🚀 Starting Docker image deployment to EC2..."

# Get variables from environment (set by GitHub Actions)
# These should be available as environment variables
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}"
REGION="${AWS_REGION:-${REGION}}"  # Try AWS_REGION first, then REGION
REPO_NAME="${ECR_REPOSITORY_EC2:-${REPO_NAME}}"  # Try ECR_REPOSITORY_EC2 first, then REPO_NAME
EC2_USER="${EC2_USER}"
EC2_IP="${EC2_IP}"
KEY_PATH="${KEY_PATH}"

# Fallback to GitHub Actions specific environment variables if not set
if [ -z "$AWS_ACCOUNT_ID" ] && [ -n "$ECR_REGISTRY_EC2" ]; then
  AWS_ACCOUNT_ID="$ECR_REGISTRY_EC2"
fi

echo "🔍 Configuration:"
echo "  - AWS Account ID: ${AWS_ACCOUNT_ID}"
echo "  - Region: ${REGION}"
echo "  - Repository: ${REPO_NAME}"
echo "  - EC2 User: ${EC2_USER}"
echo "  - EC2 IP: ${EC2_IP}"
echo "  - Key Path: ${KEY_PATH}"

# Ensure all required variables are present
REQUIRED_VARS=(AWS_ACCOUNT_ID REGION REPO_NAME EC2_USER EC2_IP KEY_PATH)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "❌ Error: $var is not set"
    echo "Available environment variables:"
    env | grep -E '^(AWS_|ECR_|REGION|REPO_|EC2_|KEY_)' | sort
    exit 1
  fi
done

# Validate SSH key file exists
if [ ! -f "$KEY_PATH" ]; then
  echo "❌ SSH key file not found at: $KEY_PATH"
  exit 1
fi

# Skip chmod if on Windows (Git Bash, WSL, or CMD/Powershell)
OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
if [[ "$OS_TYPE" == *"mingw"* || "$OS_TYPE" == *"nt"* || "$OS_TYPE" == *"msys"* ]]; then
  echo "ℹ️ Skipping chmod 600 on Windows"
else
  chmod 600 "$KEY_PATH"
fi

# Construct ECR URI
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:latest"

echo "🔄 Connecting to EC2 ($EC2_IP) and pulling Docker image..."
echo "📦 ECR URI: $ECR_URI"

# Check SSH connection before attempting commands
echo "🔍 Testing SSH connection..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -i "$KEY_PATH" "$EC2_USER@$EC2_IP" exit &>/dev/null; then
  echo "❌ Cannot establish SSH connection to $EC2_IP. Please check credentials and network."
  exit 1
fi

# SSH into EC2 to pull image from ECR
echo "🖥️ Establishing SSH connection to EC2..."
ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" "$EC2_USER@$EC2_IP" << EOF
  set -e
  
  echo "🔍 Checking EC2 instance prerequisites..."
  
  # Check if Docker is installed and running
  if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed on EC2 instance"
    exit 1
  fi
  
  if ! docker info &> /dev/null; then
    echo "❌ Docker is not running on EC2 instance"
    echo "Attempting to start Docker..."
    sudo systemctl start docker || {
      echo "❌ Failed to start Docker"
      exit 1
    }
  fi
  
  # Check if AWS CLI is installed
  if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI is not installed on EC2 instance"
    exit 1
  fi
  
  # Log in to ECR
  echo "🔑 Logging into ECR..."
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
  
  # Pull latest Docker image with retry logic
  echo "📥 Pulling latest Docker image: $ECR_URI"
  
  MAX_RETRIES=3
  retry_count=0
  pull_success=false
  
  while [ \$retry_count -lt \$MAX_RETRIES ]; do
    if docker pull "$ECR_URI"; then
      echo "✅ Successfully pulled Docker image"
      pull_success=true
      break
    else
      retry_count=\$((retry_count + 1))
      
      if [ \$retry_count -lt \$MAX_RETRIES ]; then
        echo "⚠️ Failed to pull image. Attempting disk cleanup before retry..."
        
        # Only perform cleanup if the pull failed
        echo "🧹 Performing Docker system cleanup..."
        
        # Check available disk space before cleanup
        echo "💾 Checking disk space before cleanup..."
        df -h /
        
        # Stop non-essential containers (optional, uncomment if needed)
        # echo "⏹️ Stopping non-essential containers..."
        # running_containers=\$(docker ps -q)
        # if [ -n "\$running_containers" ]; then
        #   docker stop \$running_containers || true
        # fi
        
        # Remove stopped containers
        echo "🗑️ Removing stopped containers..."
        docker container prune -f
        
        # Remove unused images
        echo "🗑️ Removing unused Docker images..."
        docker image prune -a -f
        
        # Remove build cache
        echo "🗑️ Removing Docker build cache..."
        docker builder prune -f
        
        # Remove unused volumes
        echo "🗑️ Removing unused Docker volumes..."
        docker volume prune -f
        
        # Check disk space after cleanup
        echo "💾 Checking disk space after cleanup..."
        df -h /
        
        echo "⚠️ Retrying pull in 5 seconds... (Attempt \$((retry_count + 1)) of \$MAX_RETRIES)"
        sleep 5
      else
        echo "❌ Failed to pull Docker image after \$MAX_RETRIES attempts"
        exit 1
      fi
    fi
  done
  
  if [ "\$pull_success" = true ]; then
    # Normal cleanup only if image pull was successful and CLEANUP is enabled
    if [ "${CLEANUP:-false}" = "true" ]; then
      echo "🧹 Performing light cleanup of dangling images..."
      docker image prune -f
    fi
  fi
  
  # Show Docker disk usage
  echo "📊 Docker disk usage:"
  docker system df
  
  echo "✅ Image deployment complete. Image is ready on EC2 instance."
  echo "📋 Summary:"
  echo "  - Image: $ECR_URI"
  echo "  - Status: Successfully deployed to EC2"
EOF

if [ $? -eq 0 ]; then
  echo "✅ Deployment successful: Docker image has been deployed to EC2 instance"
  echo "🎉 All operations completed successfully!"
else
  echo "❌ Deployment failed with error code: $?"
  exit 1
fi