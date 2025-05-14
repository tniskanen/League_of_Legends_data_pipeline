#!/bin/bash

set -e

# Load environment variables from variables.env
if [ -f variables.env ]; then
  export $(cat variables.env | xargs)
else
  echo "variables.env file not found. Please create it and add required variables."
  exit 1
fi

# Ensure necessary environment variables are set
REQUIRED_VARS=(AWS_ACCOUNT_ID REGION REPO_NAME)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "Error: $var is not set in variables.env"
    exit 1
  fi
done

IMAGE_NAME="$REPO_NAME:latest"
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"

# Log in to ECR
echo "Logging into ECR..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_URI"

# Build Docker image
echo "Building Docker image..."
docker build -t "$IMAGE_NAME" -f docker/ec2 .

# Tag image for ECR
echo "Tagging image..."
docker tag "$IMAGE_NAME" "$ECR_URI"

# Push to ECR
echo "Pushing image to ECR..."
docker push "$ECR_URI"

echo "✅ Docker image pushed to: $ECR_URI"
