#!/bin/bash

# Define the image name and the container name
IMAGE_NAME="207567770204.dkr.ecr.us-east-2.amazonaws.com/ec2-docker-image:latest"
CONTAINER_NAME="my_ec2_container"

# Login to ECR (AWS CLI must be configured on EC2)
echo "Logging into AWS ECR..."
aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin 207567770204.dkr.ecr.us-east-2.amazonaws.com

# Pull the latest Docker image from ECR
echo "Pulling Docker image: $IMAGE_NAME"
docker pull $IMAGE_NAME

# Run the Docker container
echo "Running Docker container..."
docker run --name $CONTAINER_NAME -d $IMAGE_NAME

# Wait for the container to exit (you could add a timeout if needed)
echo "Waiting for container to exit..."
docker wait $CONTAINER_NAME

# Clean up: Stop and remove the container after it exits
echo "Cleaning up the container..."
docker rm -f $CONTAINER_NAME

# Optionally, remove unused Docker images (prune)
echo "Pruning unused Docker images..."
docker image prune -f
