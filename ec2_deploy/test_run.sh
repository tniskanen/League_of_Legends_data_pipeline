echo "=== Local EC2 Container Runner with SSH ==="
echo "Started at: $(date)"
echo "Running from: $(pwd)"
echo "Local user: $(whoami)"

# Function for error handling
handle_error() {
  local exit_code=$1
  local error_message=$2
  echo "❌ ERROR: $error_message"
  echo "Script failed with exit code $exit_code at $(date)"
  exit "$exit_code"
}

# Function to load environment variables
load_environment_vars() {
  echo "Step 1: Loading environment variables..."
  
  # Load environment variables from variables.env (checking both current and parent directory)
  if [ -f variables.env ]; then
    echo "📄 Loading variables.env..."
    # Use source instead of export to handle more complex formats
    set -a  # automatically export all variables
    source variables.env
    set +a  # turn off automatic export
    echo "✅ Environment variables loaded from variables.env"
  elif [ -f ../variables.env ]; then
    echo "📄 Loading ../variables.env..."
    set -a  # automatically export all variables
    source ../variables.env
    set +a  # turn off automatic export
    echo "✅ Environment variables loaded from ../variables.env"
  else
    echo "❌ variables.env file not found in current or parent directory. Please create it and add required variables."
    handle_error 1 "Missing variables.env file"
  fi
  
  # Required variables for SSH connection
  REQUIRED_VARS=(EC2_IP EC2_USER KEY_PATH REPO_NAME)
  for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
      echo "❌ Error: $var is not set in variables.env"
      handle_error 2 "Missing required variable: $var"
    fi
  done
  
  # Set defaults for optional variables
  export REGION="${REGION:-us-east-1}"
  export CONTAINER_NAME="${CONTAINER_NAME:-${REPO_NAME}_container}"
  export FOLLOW_LOGS="${FOLLOW_LOGS:-true}"
  export WAIT_FOR_EXIT="${WAIT_FOR_EXIT:-true}"
  export AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
  export CLEANUP_VOLUMES="${CLEANUP_VOLUMES:-false}"
  export SSH_TIMEOUT="${SSH_TIMEOUT:-30}"
  
  # Validate key file exists
  if [ ! -f "$KEY_PATH" ]; then
    handle_error 3 "SSH key file not found: $KEY_PATH"
  fi
  
  # Set correct permissions on key file
  chmod 400 "$KEY_PATH"
  
  echo "✅ Environment setup complete"
  echo "  - EC2 IP: ${EC2_IP}"
  echo "  - EC2 User: ${EC2_USER}"
  echo "  - Key Path: ${KEY_PATH}"
  echo "  - Container: ${CONTAINER_NAME}"
  echo "  - Repository: ${REPO_NAME}"
  echo "  - Region: ${REGION}"
}

# Function to test SSH connection
test_ssh_connection() {
  echo "Step 2: Testing SSH connection to EC2..."
  
  if ssh -i "$KEY_PATH" -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no "$EC2_USER@$EC2_IP" "echo 'SSH connection successful'" 2>/dev/null; then
    echo "✅ SSH connection to $EC2_IP successful"
  else
    handle_error 4 "Failed to establish SSH connection to $EC2_IP"
  fi
}

# Function to get AWS credentials from EC2 metadata via SSH
get_aws_credentials_via_ssh() {
  echo "Step 3: Retrieving AWS credentials from EC2 metadata..."
  
  # Create a remote script to get credentials
  REMOTE_SCRIPT=$(cat << 'EOF'
#!/bin/bash
set -e

echo "🔑 Getting IMDSv2 token..."
TOKEN=$(curl -s --connect-timeout 5 --max-time 10 -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

if [ -z "$TOKEN" ]; then
  echo "ERROR: Failed to retrieve IMDSv2 token" >&2
  exit 1
fi

echo "✅ IMDSv2 token retrieved"

echo "📋 Getting IAM Role name..."
ROLE_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/)

if [ -z "$ROLE_NAME" ]; then
  echo "ERROR: Failed to retrieve IAM role name" >&2
  exit 1
fi

echo "✅ IAM Role: $ROLE_NAME"

echo "🔐 Getting credentials for role $ROLE_NAME..."
CREDS=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME)

if [ -z "$CREDS" ]; then
  echo "ERROR: Failed to retrieve AWS credentials" >&2
  exit 1
fi

# Extract credential values and output them in a format we can source
ACCESS_KEY=$(echo "$CREDS" | grep -o '"AccessKeyId" : "[^"]*' | cut -d'"' -f4)
SECRET_KEY=$(echo "$CREDS" | grep -o '"SecretAccessKey" : "[^"]*' | cut -d'"' -f4)
SESSION_TOKEN=$(echo "$CREDS" | grep -o '"Token" : "[^"]*' | cut -d'"' -f4)
EXPIRATION=$(echo "$CREDS" | grep -o '"Expiration" : "[^"]*' | cut -d'"' -f4)

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ] || [ -z "$SESSION_TOKEN" ]; then
  echo "ERROR: Failed to parse credential values" >&2
  exit 1
fi

echo "✅ Credentials retrieved successfully, expires: $EXPIRATION"

# Output credentials in a format that can be sourced
echo "export AWS_ACCESS_KEY_ID='$ACCESS_KEY'"
echo "export AWS_SECRET_ACCESS_KEY='$SECRET_KEY'"
echo "export AWS_SESSION_TOKEN='$SESSION_TOKEN'"
echo "export AWS_EXPIRATION='$EXPIRATION'"
EOF
)

  # Execute the remote script and capture credentials
  echo "🔄 Executing credential retrieval on EC2..."
  CREDS_OUTPUT=$(ssh -i "$KEY_PATH" -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no "$EC2_USER@$EC2_IP" "$REMOTE_SCRIPT" 2>&1)
  
  if [ $? -ne 0 ]; then
    echo "❌ Failed to retrieve credentials from EC2:"
    echo "$CREDS_OUTPUT"
    handle_error 5 "Failed to retrieve AWS credentials from EC2 metadata"
  fi
  
  # Extract the export statements from the output
  EXPORT_LINES=$(echo "$CREDS_OUTPUT" | grep "^export AWS_")
  
  if [ -z "$EXPORT_LINES" ]; then
    echo "❌ No credential export statements found in output:"
    echo "$CREDS_OUTPUT"
    handle_error 6 "Failed to parse AWS credentials from EC2 response"
  fi
  
  # Source the credentials locally for use in environment variables
  eval "$EXPORT_LINES"
  
  echo "✅ AWS credentials retrieved and set:"
  echo "  - Access Key ID: ${AWS_ACCESS_KEY_ID:0:10}..."
  echo "  - Secret Key: ${AWS_SECRET_ACCESS_KEY:0:4}...***"
  echo "  - Session Token: ${AWS_SESSION_TOKEN:0:10}..."
  echo "  - Expiration: $AWS_EXPIRATION"
}

# Function to run container on EC2 via SSH
run_container_via_ssh() {
  echo "Step 4: Running container on EC2..."
  
  # Construct ECR URI if AWS_ACCOUNT_ID is provided
  if [ -n "$AWS_ACCOUNT_ID" ]; then
    ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:latest"
  else
    # Try to get account ID from credentials
    echo "📋 Getting AWS Account ID..."
    AWS_ACCOUNT_ID=$(ssh -i "$KEY_PATH" -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no "$EC2_USER@$EC2_IP" \
      "export AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID' AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY' AWS_SESSION_TOKEN='$AWS_SESSION_TOKEN'; aws sts get-caller-identity --query 'Account' --output text" 2>/dev/null || echo "")
    
    if [ -n "$AWS_ACCOUNT_ID" ]; then
      ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:latest"
      echo "✅ AWS Account ID: $AWS_ACCOUNT_ID"
    else
      ECR_URI="$REPO_NAME:latest"
      echo "⚠️ Could not determine AWS Account ID, using local image name: $ECR_URI"
    fi
  fi
  
  # Build environment variables string for the container
  ENV_VARS=""
  ENV_VARS="${ENV_VARS} -e AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID'"
  ENV_VARS="${ENV_VARS} -e AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY'"
  ENV_VARS="${ENV_VARS} -e AWS_SESSION_TOKEN='$AWS_SESSION_TOKEN'"
  ENV_VARS="${ENV_VARS} -e AWS_DEFAULT_REGION='$REGION'"
  ENV_VARS="${ENV_VARS} -e AWS_REGION='$REGION'"
  
  # Add optional environment variables
  if [ -n "${HOST_PORT}" ] && [ -n "${CONTAINER_PORT}" ]; then
    PORT_MAPPING="-p ${HOST_PORT}:${CONTAINER_PORT}"
  else
    PORT_MAPPING=""
  fi
  
  if [ -n "${HOST_VOLUME}" ] && [ -n "${CONTAINER_VOLUME}" ]; then
    VOLUME_MAPPING="-v ${HOST_VOLUME}:${CONTAINER_VOLUME}"
  else
    VOLUME_MAPPING=""
  fi
  
  # Add any additional environment variables
  if [ -n "${CONTAINER_ENV_VARS}" ]; then
    for env_var in ${CONTAINER_ENV_VARS}; do
      ENV_VARS="${ENV_VARS} -e ${env_var}"
    done
  fi
  
  # Add SSM parameter if specified
  if [ -n "${SSM_PARAMETER_NAME}" ]; then
    ENV_VARS="${ENV_VARS} -e SSM_PARAMETER_NAME='${SSM_PARAMETER_NAME}'"
  fi
  
  # Create the remote execution script
  REMOTE_CONTAINER_SCRIPT=$(cat << EOF
#!/bin/bash
set -e

echo "🐳 Starting container operations on EC2..."

# Set AWS credentials in environment
export AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID'
export AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY'
export AWS_SESSION_TOKEN='$AWS_SESSION_TOKEN'
export AWS_DEFAULT_REGION='$REGION'
export AWS_REGION='$REGION'

# Login to ECR if this is an ECR image
if [[ "$ECR_URI" == *".dkr.ecr."* ]]; then
  echo "🔑 Logging into AWS ECR..."
  aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
  
  echo "📥 Pulling Docker image: $ECR_URI"
  docker pull $ECR_URI
fi

# Clean up existing container with the same name if it exists
if [ "\$(docker ps -a -q -f name=^/${CONTAINER_NAME}\$)" ]; then
  echo "🧹 Removing existing container: $CONTAINER_NAME"
  docker rm -f $CONTAINER_NAME
fi

# Run the container
echo "🚀 Running Docker container: $CONTAINER_NAME"
CONTAINER_ID=\$(docker run --name $CONTAINER_NAME \\
  -d \\
  $PORT_MAPPING \\
  $VOLUME_MAPPING \\
  $ENV_VARS \\
  ${DOCKER_RUN_ARGS:-} \\
  $ECR_URI)

echo "✅ Container started with ID: \$CONTAINER_ID"

# Follow logs if requested
if [ "$FOLLOW_LOGS" = "true" ]; then
  echo "📋 Following container logs..."
  docker logs -f $CONTAINER_NAME &
  LOGS_PID=\$!
  
  # Wait for container to exit
  if [ "$WAIT_FOR_EXIT" = "true" ]; then
    echo "⏳ Waiting for container to complete..."
    docker wait $CONTAINER_NAME
    
    # Kill the logs process
    kill \$LOGS_PID 2>/dev/null || true
    wait \$LOGS_PID 2>/dev/null || true
  fi
else
  # Just wait for container if not following logs
  if [ "$WAIT_FOR_EXIT" = "true" ]; then
    echo "⏳ Waiting for container to complete..."
    docker wait $CONTAINER_NAME
    
    echo "📋 Final container logs:"
    docker logs $CONTAINER_NAME
  fi
fi

# Get exit code
if [ "$WAIT_FOR_EXIT" = "true" ]; then
  EXIT_CODE=\$(docker inspect $CONTAINER_NAME --format='{{.State.ExitCode}}')
  echo "✅ Container exited with code: \$EXIT_CODE"
  
  # Clean up if requested
  if [ "$AUTO_CLEANUP" = "true" ]; then
    echo "🧹 Cleaning up container..."
    docker rm $CONTAINER_NAME
    
    # Optionally clean up unused Docker resources
    if [ "$CLEANUP_VOLUMES" = "true" ]; then
      echo "🧹 Cleaning up Docker volumes and dangling images..."
      docker volume prune -f
      docker image prune -f
    fi
    
    echo "✅ Cleanup completed"
  fi
  
  # Return the container's exit code
  exit \$EXIT_CODE
fi

echo "✅ Container operations completed"
EOF
)

  echo "🔄 Executing container operations on EC2..."
  echo "🐳 Container: $CONTAINER_NAME"
  echo "📦 Image: $ECR_URI"
  
  # Execute the remote container script and capture output
  ssh -i "$KEY_PATH" -o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no "$EC2_USER@$EC2_IP" "$REMOTE_CONTAINER_SCRIPT"
  CONTAINER_EXIT_CODE=$?
  
  echo "✅ Remote container operations completed with exit code: $CONTAINER_EXIT_CODE"
  return $CONTAINER_EXIT_CODE
}

# Main execution function
main() {
  echo "🚀 Starting local-to-EC2 container execution..."
  
  # Load environment variables
  load_environment_vars
  
  # Test SSH connection
  test_ssh_connection
  
  # Get AWS credentials from EC2 metadata
  get_aws_credentials_via_ssh
  
  # Run container on EC2
  run_container_via_ssh
  FINAL_EXIT_CODE=$?
  
  echo "==== Summary ===="
  echo "Script completed at $(date)"
  echo "Container exit code: $FINAL_EXIT_CODE"
  echo "Local log file: $LOG_FILE"
  
  # Return the container's exit code
  exit $FINAL_EXIT_CODE
}

# Print usage information
print_usage() {
  echo "Usage: $0"
  echo ""
  echo "Required environment variables in variables.env:"
  echo "  EC2_IP=your-ec2-public-ip"
  echo "  EC2_USER=ec2-user"
  echo "  KEY_PATH=./RIOT_EC2.pem"
  echo "  REPO_NAME=your-repo-name"
  echo "  REGION=us-east-2"
  echo ""
  echo "Optional environment variables:"
  echo "  AWS_ACCOUNT_ID=123456789012"
  echo "  CONTAINER_NAME=custom-container-name"
  echo "  HOST_PORT=8080"
  echo "  CONTAINER_PORT=80"
  echo "  HOST_VOLUME=/host/path"
  echo "  CONTAINER_VOLUME=/container/path"
  echo "  CONTAINER_ENV_VARS='VAR1=value1 VAR2=value2'"
  echo "  SSM_PARAMETER_NAME=/path/to/parameter"
  echo "  DOCKER_RUN_ARGS='--memory=1g --cpus=1'"
  echo "  FOLLOW_LOGS=true"
  echo "  WAIT_FOR_EXIT=true"
  echo "  AUTO_CLEANUP=true"
  echo "  CLEANUP_VOLUMES=false"
  echo "  SSH_TIMEOUT=30"
  echo "  DEBUG=false"
}

# Check for help flag
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  print_usage
  exit 0
fi

# Execute main function
main