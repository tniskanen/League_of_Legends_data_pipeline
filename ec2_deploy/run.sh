#!/bin/bash

# Updated run.sh - Now includes automatic EC2 shutdown after container completion
# Uses EC2 IAM Role instead of temporary credentials

set -e

# Set up logging
LOG_DIR="/tmp/container_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/container_run_$(date +%Y%m%d_%H%M%S).log"

# Also log to the main log file (this will be used by the starter script)
if [ -t 1 ]; then
    # Running interactively, use tee
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# Enable debug mode if requested
if [ "${DEBUG:-false}" = "true" ]; then
    set -x
fi

echo "=== AWS Container Runner with IAM Role and Auto-Shutdown ==="
echo "Started at: $(date)"
echo "Running as user: $(whoami)"
echo "Current directory: $(pwd)"
echo "Script PID: $$"

# Function for error handling with cleanup and shutdown
handle_error() {
    local exit_code=$1
    local error_message=$2
    echo "❌ ERROR: $error_message"
    echo "Script failed with exit code $exit_code at $(date)"
    
    # Clean up lock file on error
    rm -f "/tmp/container_job.lock"
    
    # Update status file
    cat > "/tmp/container_status.json" << EOF
{
    "status": "failed",
    "error": "$error_message",
    "end_time": "$(date -Iseconds)",
    "exit_code": $exit_code
}
EOF
    
    # Shutdown instance on error after delay
    echo "🔴 Shutting down EC2 instance due to error in 60 seconds..."
    shutdown_ec2_instance 60
    
    exit "$exit_code"
}

# Function to shutdown EC2 instance
shutdown_ec2_instance() {
    local delay_seconds=${1:-0}
    
    echo "🛑 Preparing to shutdown EC2 instance..."
    
    if [ "$delay_seconds" -gt 0 ]; then
        echo "⏳ Waiting $delay_seconds seconds before shutdown..."
        sleep "$delay_seconds"
    fi
    
    # Get instance metadata
    echo "🔍 Getting instance metadata..."
    
    # Get IMDSv2 token for security
    local token
    token=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        --connect-timeout 5 --silent) || {
        echo "⚠️ Failed to get IMDSv2 token, trying without token..."
        token=""
    }
    
    # Get instance ID and region
    local instance_id region
    if [ -n "$token" ]; then
        instance_id=$(curl -H "X-aws-ec2-metadata-token: $token" \
            --connect-timeout 5 --silent \
            "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || echo "")
        region=$(curl -H "X-aws-ec2-metadata-token: $token" \
            --connect-timeout 5 --silent \
            "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null || echo "")
    else
        instance_id=$(curl --connect-timeout 5 --silent \
            "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || echo "")
        region=$(curl --connect-timeout 5 --silent \
            "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null || echo "")
    fi
    
    if [ -z "$instance_id" ] || [ -z "$region" ]; then
        echo "❌ Failed to get instance metadata. Instance ID: '$instance_id', Region: '$region'"
        echo "⚠️ Cannot perform automatic shutdown. Manual intervention required."
        return 1
    fi
    
    echo "✅ Instance metadata retrieved:"
    echo "   Instance ID: $instance_id"
    echo "   Region: $region"
    
    # Update final status before shutdown
    cat > "/tmp/container_status.json" << EOF
{
    "status": "shutting_down",
    "instance_id": "$instance_id",
    "region": "$region",
    "shutdown_time": "$(date -Iseconds)",
    "final_log": "$LOG_FILE"
}
EOF
    
    echo "🔄 Executing shutdown command..."
    
    # Use AWS CLI to stop the instance
    if command -v aws &> /dev/null; then
        echo "📞 Using AWS CLI to stop instance..."
        aws ec2 stop-instances \
            --instance-ids "$instance_id" \
            --region "$region" \
            --output text 2>&1 || {
            echo "❌ AWS CLI shutdown failed, trying alternative method..."
            # Alternative: Use the shutdown command with delay
            echo "🔄 Using system shutdown command as fallback..."
            sudo shutdown -h +1 "Container job completed - automatic shutdown" || {
                echo "❌ System shutdown also failed. Manual intervention required."
                return 1
            }
        }
        
        echo "✅ Shutdown command executed successfully"
        echo "🏁 Instance will stop shortly. Goodbye!"
        
        # Log final message
        echo "=== SHUTDOWN INITIATED ===" >> "$LOG_FILE"
        echo "Time: $(date)" >> "$LOG_FILE"
        echo "Instance: $instance_id" >> "$LOG_FILE"
        echo "Region: $region" >> "$LOG_FILE"
        
    else
        echo "❌ AWS CLI not available, using system shutdown..."
        sudo shutdown -h +1 "Container job completed - automatic shutdown" || {
            echo "❌ System shutdown failed. Manual intervention required."
            return 1
        }
    fi
}

# Function to check Docker (same as before with minor logging improvements)
check_docker() {
    echo "🐳 Checking Docker installation and service..."
    
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker is not installed. Installing Docker..."
        sudo yum update -y
        sudo yum install -y docker
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -a -G docker ec2-user
        echo "✅ Docker installed and configured"
        DOCKER_CMD="sudo docker"
    else
        echo "✅ Docker is already installed"
        
        if ! sudo systemctl is-active --quiet docker; then
            echo "🔄 Starting Docker service..."
            sudo systemctl start docker
        fi
        
        if docker ps &> /dev/null; then
            DOCKER_CMD="docker"
            echo "✅ Docker service is running and accessible"
        else
            echo "⚠️ Using sudo for Docker commands"
            DOCKER_CMD="sudo docker"
        fi
    fi
    
    $DOCKER_CMD --version
    echo "✅ Docker check completed"
}

# Function to verify IAM role credentials (same as before)
verify_iam_credentials() {
    echo "🔐 Verifying IAM role credentials..."
    
    # Test AWS CLI access
    if ! command -v aws &> /dev/null; then
        echo "📦 Installing AWS CLI..."
        sudo yum install -y aws-cli
    fi
    
    # Test credentials by getting caller identity
    CALLER_IDENTITY=$(aws sts get-caller-identity 2>/dev/null || echo "")
    
    if [ -z "$CALLER_IDENTITY" ]; then
        handle_error 1 "Failed to get AWS credentials from IAM role. Ensure EC2 instance has an IAM role attached."
    fi
    
    # Extract account ID and role info
    AWS_ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*' | cut -d'"' -f4)
    USER_ARN=$(echo "$CALLER_IDENTITY" | grep -o '"Arn": "[^"]*' | cut -d'"' -f4)
    
    echo "✅ IAM role credentials verified successfully"
    echo "   Account ID: $AWS_ACCOUNT_ID"
    echo "   Role ARN: $USER_ARN"
    
    export AWS_ACCOUNT_ID
}

# Function to load environment variables (same as before)
load_environment_vars() {
    echo "📝 Loading environment variables..."
    
    # Get the directory where the script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Try to load variables.env from multiple locations
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
        echo "⚠️ variables.env file not found, using defaults and environment"
    fi
    
    # Get region from instance metadata
    if [ -z "$REGION" ]; then
        echo "🔍 Getting region from instance metadata..."
        REGION=$(curl -s --connect-timeout 5 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")
    fi
    
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    
    # Set defaults
    export REPO_NAME="${REPO_NAME:-default_repo}"
    export CONTAINER_NAME="${CONTAINER_NAME:-${REPO_NAME}_container}"
    export FOLLOW_LOGS="${FOLLOW_LOGS:-true}"
    export WAIT_FOR_EXIT="${WAIT_FOR_EXIT:-true}"
    export AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
    export CLEANUP_VOLUMES="${CLEANUP_VOLUMES:-false}"
    export AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-true}"  # New variable for auto-shutdown
    
    # Validate required variables
    if [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$REGION" ] || [ -z "$REPO_NAME" ]; then
        handle_error 2 "Missing required variables (AWS_ACCOUNT_ID, REGION, REPO_NAME)"
    fi
    
    # Construct ECR URI
    export ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:latest"
    
    echo "✅ Environment setup complete"
    echo "   AWS Account: ${AWS_ACCOUNT_ID}"
    echo "   Region: ${REGION}"
    echo "   Container: ${CONTAINER_NAME}"
    echo "   Image: ${ECR_URI}"
    echo "   Auto-shutdown: ${AUTO_SHUTDOWN}"
}

# Function to set up container parameters (same as before)
setup_container_params() {
    echo "🔧 Setting up container parameters..."
    
    # Port mapping
    PORT_MAPPING=""
    if [ -n "${HOST_PORT}" ] && [ -n "${CONTAINER_PORT}" ]; then
        PORT_MAPPING="-p ${HOST_PORT}:${CONTAINER_PORT}"
        echo "   Port mapping: ${HOST_PORT}:${CONTAINER_PORT}"
    fi
    
    # Volume mapping
    VOLUME_MAPPING=""
    if [ -n "${HOST_VOLUME}" ] && [ -n "${CONTAINER_VOLUME}" ]; then
        VOLUME_MAPPING="-v ${HOST_VOLUME}:${CONTAINER_VOLUME}"
        echo "   Volume mapping: ${HOST_VOLUME}:${CONTAINER_VOLUME}"
    fi
    
    # Environment variables for container
    ENV_VARS=""
    if [ -n "${CONTAINER_ENV_FILE}" ] && [ -f "${CONTAINER_ENV_FILE}" ]; then
        ENV_VARS="--env-file ${CONTAINER_ENV_FILE}"
    elif [ -n "${CONTAINER_ENV_VARS}" ]; then
        for env_var in ${CONTAINER_ENV_VARS}; do
            ENV_VARS="${ENV_VARS} -e ${env_var}"
        done
    fi
    
    # Add SSM parameter name if specified
    if [ -n "${SSM_PARAMETER_NAME}" ]; then
        ENV_VARS="${ENV_VARS} -e SSM_PARAMETER_NAME=${SSM_PARAMETER_NAME}"
    fi
    
    # Pass AWS region to container
    ENV_VARS="${ENV_VARS} -e AWS_DEFAULT_REGION=${REGION}"
    ENV_VARS="${ENV_VARS} -e AWS_REGION=${REGION}"
    
    # Extra Docker arguments
    EXTRA_ARGS="${DOCKER_RUN_ARGS:-}"
    
    echo "✅ Container parameters configured"
}

# Updated function to run container with automatic shutdown
run_container() {
    echo "🚀 Running container with IAM role and auto-shutdown..."
    
    # Login to ECR
    if [[ "$ECR_URI" == *".dkr.ecr."* ]]; then
        echo "🔑 Logging into AWS ECR..."
        aws ecr get-login-password --region "${REGION}" | $DOCKER_CMD login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" || {
            handle_error 3 "Failed to login to ECR"
        }
        
        echo "📥 Pulling Docker image: ${ECR_URI}"
        $DOCKER_CMD pull "${ECR_URI}" || {
            handle_error 4 "Failed to pull Docker image: ${ECR_URI}"
        }
    fi
    
    # Clean up existing container
    if [ "$($DOCKER_CMD ps -a -q -f name=^/${CONTAINER_NAME}$)" ]; then
        echo "🧹 Removing existing container: ${CONTAINER_NAME}"
        $DOCKER_CMD rm -f ${CONTAINER_NAME}
    fi
    
    # Update status
    cat > "/tmp/container_status.json" << EOF
{
    "status": "starting_container",
    "pid": $$,
    "start_time": "$(date -Iseconds)",
    "container_name": "$CONTAINER_NAME"
}
EOF

    # Run container with IAM role
    echo "🏃 Starting Docker container: ${CONTAINER_NAME}"
    CONTAINER_ID=$($DOCKER_CMD run --name "${CONTAINER_NAME}" \
        -d \
        ${PORT_MAPPING} \
        ${VOLUME_MAPPING} \
        ${ENV_VARS} \
        ${EXTRA_ARGS} \
        "${ECR_URI}")
    
    if [ $? -eq 0 ]; then
        echo "✅ Container started with ID: ${CONTAINER_ID}"
        
        # Update status
        cat > "/tmp/container_status.json" << EOF
{
    "status": "container_running",
    "pid": $$,
    "container_id": "$CONTAINER_ID",
    "container_name": "$CONTAINER_NAME",
    "start_time": "$(date -Iseconds)"
}
EOF
    else
        handle_error 5 "Failed to start container"
    fi
    
    # Follow logs if requested
    if [ "${FOLLOW_LOGS:-true}" = "true" ]; then
        echo "📋 Following container logs... (Container will continue running)"
        $DOCKER_CMD logs -f ${CONTAINER_NAME} &
        LOGS_PID=$!
        
        # Handle Ctrl+C gracefully
        trap "kill $LOGS_PID 2>/dev/null || true; echo '📋 Stopped following logs, container still running'" INT
        wait $LOGS_PID 2>/dev/null || true
        trap - INT
    fi
    
    # Wait for container completion
    if [ "${WAIT_FOR_EXIT:-true}" = "true" ]; then
        echo "⏳ Waiting for container to complete (this may take 4-6 hours)..."
        $DOCKER_CMD wait ${CONTAINER_NAME}
        
        # Get final status
        EXIT_CODE=$($DOCKER_CMD inspect ${CONTAINER_NAME} --format='{{.State.ExitCode}}')
        echo "✅ Container completed with exit code: ${EXIT_CODE}"
        
        # Show final logs if not already following
        if [ "${FOLLOW_LOGS:-true}" != "true" ]; then
            echo "📋 Final container logs:"
            $DOCKER_CMD logs --tail 50 ${CONTAINER_NAME}
        fi
        
        # Update final status
        cat > "/tmp/container_status.json" << EOF
{
    "status": "completed",
    "pid": $$,
    "container_id": "$CONTAINER_ID",
    "exit_code": $EXIT_CODE,
    "end_time": "$(date -Iseconds)"
}
EOF
        
        # Cleanup
        if [ "${AUTO_CLEANUP:-true}" = "true" ]; then
            echo "🧹 Cleaning up container..."
            $DOCKER_CMD rm -f "${CONTAINER_NAME}"
            
            if [ "${CLEANUP_VOLUMES:-false}" = "true" ]; then
                echo "🧹 Cleaning up Docker volumes..."
                $DOCKER_CMD volume prune -f
                $DOCKER_CMD image prune -f
            fi
        fi
        
        # Clean up lock file
        rm -f "/tmp/container_job.lock"
        
        echo "🎉 Job completed successfully!"
        
        # AUTO-SHUTDOWN: Shutdown EC2 instance if enabled
        if [ "${AUTO_SHUTDOWN:-true}" = "true" ]; then
            echo ""
            echo "🛑 AUTO-SHUTDOWN ENABLED"
            echo "Container job completed, initiating EC2 instance shutdown..."
            shutdown_ec2_instance 30  # 30 second delay to allow logs to be written
        else
            echo "⚠️ Auto-shutdown disabled. Instance will remain running."
        fi
        
        return $EXIT_CODE
    fi
}

# Main execution function
main() {
    echo "🎬 Starting main execution..."
    
    # Set up trap for cleanup on script termination
    trap 'echo "🚨 Script interrupted, cleaning up..."; rm -f "/tmp/container_job.lock"; exit 1' INT TERM
    
    # Create lock file to prevent multiple instances
    if [ -f "/tmp/container_job.lock" ]; then
        echo "⚠️ Another container job is already running (lock file exists)"
        exit 1
    fi
    
    echo $$ > "/tmp/container_job.lock"
    
    check_docker
    verify_iam_credentials
    load_environment_vars
    setup_container_params
    run_container
    
    echo ""
    echo "==== Final Summary ===="
    echo "✅ Script completed successfully at $(date)"
    echo "📋 Log saved at: $LOG_FILE"
    echo "🔐 Used IAM role credentials (auto-refreshing)"
    echo "⏱️ No timeout limitations!"
    echo "🛑 Auto-shutdown: ${AUTO_SHUTDOWN:-true}"
}

# Execute 