#!/bin/bash

# Combined script for:
# 1. Retrieving AWS credentials from EC2 instance metadata
# 2. Running Docker containers with these credentials
# 3. Tracking container progress and cleaning up after completion
#
# Author: Claude
# Date: May 21, 2025

# Exit on error by default (can be overridden with DEBUG=true)
set -e

# Set up logging
LOG_DIR="/tmp/container_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/container_run_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Enable command tracing for verbose output if DEBUG is set
if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

echo "=== AWS Container Runner with Metadata Credentials ==="
echo "Started at: $(date)"
echo "Running as user: $(whoami)"
echo "Current directory: $(pwd)"
echo "Script location: $0"

# Function for error handling
handle_error() {
  local exit_code=$1
  local error_message=$2
  echo "❌ ERROR: $error_message"
  echo "Script failed with exit code $exit_code at $(date)"
  exit "$exit_code"
}

# Function to check Docker installation and start service
check_docker() {
  echo "🐳 Checking Docker installation and service..."
  
  # Check if Docker is installed
  if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Installing Docker..."
    
    # Install Docker on Amazon Linux 2
    sudo yum update -y
    sudo yum install -y docker
    
    # Start Docker service
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Add ec2-user to docker group
    sudo usermod -a -G docker ec2-user
    
    echo "✅ Docker installed and configured"
    echo "⚠️ Note: You may need to log out and back in for group changes to take effect"
    
    # Try to use Docker with sudo for this session
    DOCKER_CMD="sudo docker"
  else
    echo "✅ Docker is already installed"
    
    # Check if Docker service is running
    if ! sudo systemctl is-active --quiet docker; then
      echo "🔄 Starting Docker service..."
      sudo systemctl start docker
    fi
    
    # Check if current user can use Docker without sudo
    if docker ps &> /dev/null; then
      DOCKER_CMD="docker"
      echo "✅ Docker service is running and accessible"
    else
      echo "⚠️ Using sudo for Docker commands"
      DOCKER_CMD="sudo docker"
    fi
  fi
  
  # Verify Docker is working
  $DOCKER_CMD --version
  echo "✅ Docker check completed"
}

# Function to get IMDSv2 token with fallback
get_imdsv2_token() {
  echo "Step 1: Getting IMDSv2 token..."
  
  # Temporarily disable exit on error for the token retrieval
  set +e
  
  TOKEN=$(curl -s --connect-timeout 3 --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  TOKEN_CURL_EXIT=$?
  
  # Re-enable exit on error
  set -e
  
  if [ $TOKEN_CURL_EXIT -ne 0 ]; then
    echo "⚠️ Warning: Failed to retrieve IMDSv2 token (curl exit code: $TOKEN_CURL_EXIT)"
    return 1
  elif [ -z "$TOKEN" ]; then
    echo "⚠️ Warning: Retrieved empty IMDSv2 token"
    return 1
  else
    echo "✅ IMDSv2 token retrieved successfully: ${TOKEN:0:10}..."
    return 0
  fi
}

# Function to get IAM role credentials
get_iam_credentials() {
  echo "Step 2: Getting IAM Role name..."
  
  ROLE_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/)
  
  if [ -z "$ROLE_NAME" ]; then
    echo "⚠️ No IAM role found attached to this instance"
    return 1
  else
    echo "✅ IAM Role name retrieved: $ROLE_NAME"
  fi
  
  echo "Step 3: Getting temporary credentials for role $ROLE_NAME..."
  CREDS=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME)
  
  if [ -z "$CREDS" ]; then
    echo "⚠️ Failed to retrieve AWS credentials"
    return 1
  else
    echo "✅ AWS credentials retrieved successfully"
  fi
  
  # Extract credential values
  echo "Step 4: Parsing credentials..."
  ACCESS_KEY=$(echo "$CREDS" | grep -o '"AccessKeyId" : "[^"]*' | cut -d'"' -f4)
  SECRET_KEY=$(echo "$CREDS" | grep -o '"SecretAccessKey" : "[^"]*' | cut -d'"' -f4)
  SESSION_TOKEN=$(echo "$CREDS" | grep -o '"Token" : "[^"]*' | cut -d'"' -f4)
  EXPIRATION=$(echo "$CREDS" | grep -o '"Expiration" : "[^"]*' | cut -d'"' -f4)
  
  if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ] || [ -z "$SESSION_TOKEN" ]; then
    echo "⚠️ Failed to parse credential values from metadata response"
    return 1
  else
    echo "✅ Credentials parsed successfully, expiration: $EXPIRATION"
    export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
    export AWS_SESSION_TOKEN="$SESSION_TOKEN"
    return 0
  fi
}

# Function to load environment variables
load_environment_vars() {
  echo "Step 5: Loading environment variables..."
  echo "Looking for variables.env in the following locations:"

  # Get the directory where the script is located
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "  - Script directory: $SCRIPT_DIR"
  echo "  - Current directory: $(pwd)"
  echo "  - Home directory: $HOME"

  if [ -f "$SCRIPT_DIR/variables.env" ]; then
    set -o allexport
    source "$SCRIPT_DIR/variables.env"
    set +o allexport
    echo "✅ Environment variables loaded from $SCRIPT_DIR/variables.env"
  elif [ -f "./variables.env" ]; then
    set -o allexport
    source ./variables.env
    set +o allexport
    echo "✅ Environment variables loaded from ./variables.env"
  elif [ -f "/home/ec2-user/variables.env" ]; then
    set -o allexport
    source /home/ec2-user/variables.env
    set +o allexport
    echo "✅ Environment variables loaded from /home/ec2-user/variables.env"
  else
    echo "⚠️ variables.env file not found in any expected location"
    echo "Available files in current directory:"
    ls -la
    echo "Available files in script directory:"
    ls -la "$SCRIPT_DIR"
    echo "Available files in /home/ec2-user:"
    ls -la /home/ec2-user/
    echo "Using default values and environment variables."
  fi
  
  # Set default values for required variables if not already set
  # Get AWS Account ID if not set
  if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "🔍 AWS_ACCOUNT_ID not set, attempting to retrieve from AWS STS..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "")
    if [ -z "$AWS_ACCOUNT_ID" ]; then
      handle_error 2 "Could not determine AWS_ACCOUNT_ID"
    fi
  fi
  
  # Get region if not set
  if [ -z "$REGION" ]; then
    echo "🔍 REGION not set, attempting to retrieve from instance metadata..."
    REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")
  fi
  
  export AWS_DEFAULT_REGION="${REGION}"
  
  # Container settings
  export REPO_NAME="${REPO_NAME:-default_repo}"
  export CONTAINER_NAME="${CONTAINER_NAME:-${REPO_NAME}_container}"
  
  # Optional settings with defaults
  export FOLLOW_LOGS="${FOLLOW_LOGS:-true}"
  export WAIT_FOR_EXIT="${WAIT_FOR_EXIT:-true}"
  export AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
  export CLEANUP_VOLUMES="${CLEANUP_VOLUMES:-false}"
  
  # Check critical variables
  if [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$REGION" ] || [ -z "$REPO_NAME" ]; then
    handle_error 2 "Failed to set one or more required variables (AWS_ACCOUNT_ID, REGION, REPO_NAME)"
  fi
  
  # Construct ECR URI
  export ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:latest"
  
  echo "✅ Environment setup complete"
  echo "  - AWS Account: ${AWS_ACCOUNT_ID}"
  echo "  - Region: ${REGION}"
  echo "  - Container name: ${CONTAINER_NAME}"
  echo "  - Image: ${ECR_URI}"
}

# Function to set up Docker container parameters
setup_container_params() {
  echo "Step 6: Setting up container parameters..."
  
  # Optional port mapping
  PORT_MAPPING=""
  if [ -n "${HOST_PORT}" ] && [ -n "${CONTAINER_PORT}" ]; then
    PORT_MAPPING="-p ${HOST_PORT}:${CONTAINER_PORT}"
    echo "  - Port mapping: ${HOST_PORT}:${CONTAINER_PORT}"
  fi
  
  # Optional volume mounting
  VOLUME_MAPPING=""
  if [ -n "${HOST_VOLUME}" ] && [ -n "${CONTAINER_VOLUME}" ]; then
    VOLUME_MAPPING="-v ${HOST_VOLUME}:${CONTAINER_VOLUME}"
    echo "  - Volume mapping: ${HOST_VOLUME}:${CONTAINER_VOLUME}"
  fi
  
  # Optional environment variables to pass to container
  ENV_VARS=""
  if [ -n "${CONTAINER_ENV_FILE}" ] && [ -f "${CONTAINER_ENV_FILE}" ]; then
    ENV_VARS="--env-file ${CONTAINER_ENV_FILE}"
  elif [ -n "${CONTAINER_ENV_VARS}" ]; then
    # Format: "VAR1=value1 VAR2=value2"
    for env_var in ${CONTAINER_ENV_VARS}; do
      ENV_VARS="${ENV_VARS} -e ${env_var}"
    done
  fi
  
  # Add SSM parameter name as environment variable if specified
  if [ -n "${SSM_PARAMETER_NAME}" ]; then
    echo "📝 Setting SSM parameter name for container access: ${SSM_PARAMETER_NAME}"
    ENV_VARS="${ENV_VARS} -e SSM_PARAMETER_NAME=${SSM_PARAMETER_NAME}"
  fi
  
  # Add AWS credentials as environment variables for Docker
  ENV_VARS="${ENV_VARS} -e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
  ENV_VARS="${ENV_VARS} -e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
  ENV_VARS="${ENV_VARS} -e AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}"
  ENV_VARS="${ENV_VARS} -e AWS_DEFAULT_REGION=${REGION}"
  ENV_VARS="${ENV_VARS} -e AWS_REGION=${REGION}"
  
  # Optional extra Docker run arguments
  EXTRA_ARGS="${DOCKER_RUN_ARGS:-}"
  
  echo "✅ Container parameters set up successfully"
}

run_container() {
  echo "Step 7: Running container..."
  
  # Login to ECR if needed
  if [[ "$ECR_URI" == *".dkr.ecr."* ]]; then
    echo "🔑 Logging into AWS ECR..."
    aws ecr get-login-password --region "${REGION}" | $DOCKER_CMD login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" || {
      handle_error 3 "Failed to login to ECR"
    }
    
    # Pull the latest image
    echo "📥 Pulling Docker image: ${ECR_URI}"
    $DOCKER_CMD pull "${ECR_URI}" || {
      handle_error 4 "Failed to pull Docker image: ${ECR_URI}"
    }
  fi
  
  # Clean up existing container with the same name if it exists
  if [ "$($DOCKER_CMD ps -a -q -f name=^/${CONTAINER_NAME}$)" ]; then
    echo "🧹 Removing existing container: ${CONTAINER_NAME}"
    $DOCKER_CMD rm -f ${CONTAINER_NAME}
  fi
  
  # Create AWS credentials directory in container's home
  echo "Step 8: Setting up AWS credentials directory for container..."
  
  # Create a temporary credentials file
  mkdir -p /tmp/.aws/
  cat > /tmp/.aws/credentials << EOL
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
aws_session_token = ${AWS_SESSION_TOKEN}
region = ${REGION}
EOL

  cat > /tmp/.aws/config << EOL
[default]
region = ${REGION}
output = json
EOL

  echo "✅ AWS credentials files created successfully"
  
  # Add volume mapping for AWS credentials
  VOLUME_MAPPING="${VOLUME_MAPPING} -v /tmp/.aws:/root/.aws:ro"
  
  # Run the container
  echo "🚀 Running Docker container: ${CONTAINER_NAME}"
  echo "Command: $DOCKER_CMD run --name ${CONTAINER_NAME} -d ${PORT_MAPPING} ${VOLUME_MAPPING} ${ENV_VARS} ${EXTRA_ARGS} ${ECR_URI}"
  
  CONTAINER_ID=$($DOCKER_CMD run --name "${CONTAINER_NAME}" \
    -d \
    ${PORT_MAPPING} \
    ${VOLUME_MAPPING} \
    ${ENV_VARS} \
    ${EXTRA_ARGS} \
    "${ECR_URI}")
  
  if [ $? -eq 0 ]; then
    echo "✅ Container started with ID: ${CONTAINER_ID}"
  else
    handle_error 5 "Failed to start container"
  fi
  
  # Follow container logs if requested
  if [ "${FOLLOW_LOGS:-true}" = "true" ]; then
    echo "📋 Following container logs... (Press Ctrl+C to stop following logs but continue execution)"
    $DOCKER_CMD logs -f ${CONTAINER_NAME} &
    LOGS_PID=$!
    
    # Allow user to cancel log following but continue script
    trap "kill $LOGS_PID 2>/dev/null || true" INT
    
    # Wait for logs process to finish or be killed
    wait $LOGS_PID 2>/dev/null || true
    
    # Reset trap
    trap - INT
  fi
  
  # Wait for container to exit if requested
  if [ "${WAIT_FOR_EXIT:-true}" = "true" ]; then
    echo "⏳ Waiting for container to complete..."
    $DOCKER_CMD wait ${CONTAINER_NAME}
    
    # Show logs on completion if we weren't already following
    if [ "${FOLLOW_LOGS:-true}" != "true" ]; then
      echo "📋 Container logs:"
      $DOCKER_CMD logs ${CONTAINER_NAME}
    fi
    
    # Get exit code
    EXIT_CODE=$($DOCKER_CMD inspect ${CONTAINER_NAME} --format='{{.State.ExitCode}}')
    echo "✅ Container exited with code: ${EXIT_CODE}"
    
    # Clean up if requested
    if [ "${AUTO_CLEANUP:-true}" = "true" ]; then
      echo "🧹 Cleaning up container..."
      $DOCKER_CMD rm -f "${CONTAINER_NAME}"
      
      # Clean up temp AWS credentials
      rm -rf /tmp/.aws/
      
      # Optionally clean up unused Docker resources
      if [ "${CLEANUP_VOLUMES:-false}" = "true" ]; then
        echo "🧹 Cleaning up Docker volumes and dangling images..."
        $DOCKER_CMD volume prune -f
        $DOCKER_CMD image prune -f
      fi
    fi
  fi
}

# Main execution starts here
main() {
  # Check Docker installation and service
  check_docker
  
  # Get IMDSv2 token
  get_imdsv2_token
  TOKEN_SUCCESS=$?
  
  # Get IAM credentials
  if [ $TOKEN_SUCCESS -eq 0 ]; then
    get_iam_credentials
    CREDS_SUCCESS=$?
  else
    CREDS_SUCCESS=1
  fi
  
  # Load environment variables
  load_environment_vars
  
  # Set up container parameters
  setup_container_params
  
  # Run container
  run_container
  
  echo "==== Summary ===="
  echo "Script completed successfully at $(date)"
  echo "Log file saved at: $LOG_FILE"
  echo "CloudWatch logging: ❌ Disabled (removed for simplicity)"
}

# Execute main function
main