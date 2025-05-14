#!/bin/bash

set -e

# Load environment variables
if [ -f variables.env ]; then
  export $(cat variables.env | xargs)
else
  echo "variables.env file not found. Please create it and add required variables."
  exit 1
fi

# Ensure all required variables are present
REQUIRED_VARS=(AWS_ACCOUNT_ID REGION REPO_NAME EC2_USER EC2_IP KEY_PATH)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "Error: $var is not set in variables.env"
    exit 1
  fi
done

# Construct ECR URI
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:latest"

echo "Connecting to EC2 and pulling Docker image (without running)..."

# SSH into EC2 to pull image from ECR
ssh -i "$KEY_PATH" "$EC2_USER@$EC2_IP" << EOF
  set -e

  echo "Logging into ECR..."
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ECR_URI%:*}"

  echo "Pulling latest Docker image..."
  docker pull "$ECR_URI"

  echo "✅ Image pulled to EC2. Not running container."
EOF
