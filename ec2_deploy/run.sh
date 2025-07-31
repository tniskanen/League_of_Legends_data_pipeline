#!/bin/bash

# Updated run.sh - Now includes automatic EC2 shutdown after container completion
# Uses EC2 IAM Role instead of temporary credentials
# FIXED: Better lock file handling and race condition prevention

set -e

# Set up logging
LOG_DIR="/tmp/container_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/container_run_$(date +%Y%m%d_%H%M%S).log"

# FIXED: Ultra-simple logging setup that works in both interactive and background modes
exec > >(tee -a "$LOG_FILE") 2>&1

# Enable debug mode if requested
if [ "${DEBUG:-false}" = "true" ]; then
    set -x
fi

echo "=== AWS Container Runner with IAM Role and Auto-Shutdown ==="
echo "Started at: $(date)"
echo "Running as user: $(whoami)"
echo "Current directory: $(pwd)"
echo "Script PID: $$"
echo "Running mode: $(if [ -t 0 ]; then echo 'interactive'; else echo 'background'; fi)"

# FIXED: Simplified lock file verification
LOCK_FILE="/tmp/container_job.lock"
if [ ! -f "$LOCK_FILE" ]; then
    echo "❌ ERROR: No lock file found. This script should be started via ssm_starter.sh"
    exit 1
fi

# Check if we're the process that should be running
LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
if [ "$LOCK_PID" = "$$" ]; then
    echo "✅ Lock file verified - we are the authorized process"
else
    echo "⚠️ Lock file PID ($LOCK_PID) differs from our PID ($$)"
    echo "This is normal when started via ssm_starter.sh - proceeding..."
fi

# Function for error handling with cleanup and shutdown
handle_error() {
    local exit_code=$1
    local error_message=$2
    echo "❌ ERROR: $error_message"
    echo "Script failed with exit code $exit_code at $(date)"
    
    # Clean up lock file on error
    rm -f "$LOCK_FILE"
    
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

# Function to send logs to CloudWatch
send_logs_to_cloudwatch() {
    local log_file="$1"
    local log_group="$2"
    local instance_id="$3"
    
    if [ "${SEND_LOGS_TO_CLOUDWATCH:-false}" != "true" ]; then
        echo "📋 CloudWatch logging disabled, skipping log upload"
        return 0
    fi
    
    echo "📤 Sending logs to CloudWatch..."
    
    # Create log stream name with timestamp
    local log_stream="container-$(date +%Y%m%d-%H%M%S)-${instance_id}"
    
    # Check if log group exists, create if not
    echo "📝 Checking if CloudWatch log group exists: $log_group"
    if aws logs describe-log-groups --log-group-name-prefix "$log_group" --query "logGroups[?logGroupName=='$log_group'].logGroupName" --output text 2>/dev/null | grep -q "$log_group"; then
        echo "✅ Log group already exists: $log_group"
    else
        echo "📝 Creating CloudWatch log group: $log_group"
        aws logs create-log-group --log-group-name "$log_group" 2>/dev/null || {
            echo "⚠️ Log group may already exist, continuing..."
        }
        
        # Set retention policy
        echo "📝 Setting retention policy to ${CLOUDWATCH_RETENTION_DAYS:-7} days"
        aws logs put-retention-policy --log-group-name "$log_group" --retention-in-days "${CLOUDWATCH_RETENTION_DAYS:-7}" 2>/dev/null || {
            echo "⚠️ Failed to set retention policy, continuing anyway"
        }
    fi
    
    # Create log stream
    echo "📝 Creating log stream: $log_stream"
    aws logs create-log-stream --log-group-name "$log_group" --log-stream-name "$log_stream" || {
        echo "⚠️ Failed to create log stream, continuing without CloudWatch logs"
        return 1
    }
    
    # Upload log file to CloudWatch
    if [ -f "$log_file" ]; then
        echo "📤 Uploading log file to CloudWatch..."
        
        # Convert log file to CloudWatch format and upload
        local temp_events_file="/tmp/cloudwatch_events.json"
        
        # Create events in CloudWatch format
        cat "$log_file" | while IFS= read -r line; do
            echo "{\"timestamp\": $(date +%s)000, \"message\": \"$line\"}"
        done > "$temp_events_file"
        
        # Upload to CloudWatch
        aws logs put-log-events \
            --log-group-name "$log_group" \
            --log-stream-name "$log_stream" \
            --log-events file://"$temp_events_file" || {
            echo "⚠️ Failed to upload logs to CloudWatch"
            rm -f "$temp_events_file"
            return 1
        }
        
        rm -f "$temp_events_file"
        echo "✅ Logs successfully uploaded to CloudWatch"
        echo "   Log Group: $log_group"
        echo "   Log Stream: $log_stream"
    else
        echo "⚠️ Log file not found: $log_file"
        return 1
    fi
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

# Function to check Docker
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

# Function to verify IAM role credentials
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

# Function to load environment variables
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
    export AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-true}"
    export SEND_LOGS_TO_CLOUDWATCH="${SEND_LOGS_TO_CLOUDWATCH:-false}"
    export CLOUDWATCH_LOG_GROUP="${CLOUDWATCH_LOG_GROUP:-/aws/ec2/containers/default}"
    export CLOUDWATCH_RETENTION_DAYS="${CLOUDWATCH_RETENTION_DAYS:-7}"
    
    echo "🔐 Loading sensitive variables from SSM..."

    export AWS_ACCOUNT_ID=$(aws ssm get-parameter --name "ACCOUNT_ID" --with-decryption --query "Parameter.Value" --output text)

    if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "❌ Failed to load AWS_ACCOUNT_ID from SSM"
    handle_error 3 "Unable to retrieve ACCOUNT_ID from SSM"
    fi

    # Validate required variables
    if [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$REGION" ] || [ -z "$REPO_NAME" ]; then
        handle_error 2 "Missing required variables (AWS_ACCOUNT_ID, REGION, REPO_NAME)"
    fi
    
    # Determine RUN_MODE
    if [ "${RUN_MODE}" == "test" ]; then
        export PLAYER_LIMIT=100
        export BUCKET_NAME='lol-match-test'
    else
        export PLAYER_LIMIT=100000
        export BUCKET_NAME='lol-match-jsons'
    fi 

    # Construct ECR URI
    export ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:latest"
    
    echo "✅ Loaded sensitive values from SSM"
    echo "✅ Environment setup complete"
    echo "   AWS Account: ${AWS_ACCOUNT_ID}"
    echo "   Region: ${REGION}"
    echo "   Container: ${CONTAINER_NAME}"
    echo "   Image: ${ECR_URI}"
    echo "   Auto-shutdown: ${AUTO_SHUTDOWN}"
    echo "   PLAYER LIMIT SET TO ${PLAYER_LIMIT}"
    echo "   BUCKET SET TO ${BUCKET_NAME}"
}

# Function to set up container parameters
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
    ENV_VARS="${ENV_VARS} -e PLAYER_LIMIT=${PLAYER_LIMIT}"
    ENV_VARS="${ENV_VARS} -e BUCKET_NAME=${BUCKET_NAME}"
    
    # Extra Docker arguments
    EXTRA_ARGS="${DOCKER_RUN_ARGS:-}"
    
    echo "✅ Container parameters configured"
}

# FIXED: Enhanced function to run container with better error handling (NO TIMEOUT)
run_container() {
    echo "🚀 Running container with IAM role and auto-shutdown..."
    
    # Check if a container with the same name is already running
    if $DOCKER_CMD ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        echo "⚠️ Container ${CONTAINER_NAME} is already running. Stopping it first..."
        $DOCKER_CMD stop "${CONTAINER_NAME}" || true
        $DOCKER_CMD rm "${CONTAINER_NAME}" || true
    fi
    
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
    
    # Clean up any existing container with the same name
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

    # Show the Docker command being executed
    echo "🔍 Running Docker command:"
    echo "$DOCKER_CMD run --name ${CONTAINER_NAME} -d ${PORT_MAPPING} ${VOLUME_MAPPING} ${ENV_VARS} ${EXTRA_ARGS} ${ECR_URI}"

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
        
        # Wait a moment for container to initialize
        sleep 3
        
        # Check if container is still running
        if ! $DOCKER_CMD ps -q -f "name=${CONTAINER_NAME}" | grep -q .; then
            echo "❌ Container stopped immediately after starting!"
            echo "🔍 Container logs:"
            $DOCKER_CMD logs "${CONTAINER_NAME}"
            echo "🔍 Container exit code:"
            $DOCKER_CMD inspect "${CONTAINER_NAME}" --format='{{.State.ExitCode}}'
            handle_error 5 "Container exited immediately"
        fi
        
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
    
    # Wait for container completion with proper cleanup
    if [ "${WAIT_FOR_EXIT:-true}" = "true" ]; then
        echo "⏳ Waiting for container to complete..."
        
        # Start log following in background if requested
        if [ "${FOLLOW_LOGS:-true}" = "true" ]; then
            echo "📋 Following container logs in background..."
            $DOCKER_CMD logs -f ${CONTAINER_NAME} &
            LOGS_PID=$!
        fi
        
        # Wait for container to exit with more frequent checks
        echo "🔍 Monitoring container status..."
        while true; do
            if ! $DOCKER_CMD ps -q -f "name=${CONTAINER_NAME}" | grep -q .; then
                echo "✅ Container has exited"
                break
            fi
            sleep 10  # Check every 10 seconds
            echo "⏱️ Container still running at $(date)..."
        done
        
        # Kill log following process if it's still running
        if [ "${FOLLOW_LOGS:-true}" = "true" ] && [ -n "$LOGS_PID" ]; then
            echo "📋 Stopping log following process..."
            kill $LOGS_PID 2>/dev/null || true
            wait $LOGS_PID 2>/dev/null || true
        fi
        
        # Get final status
        EXIT_CODE=$($DOCKER_CMD inspect ${CONTAINER_NAME} --format='{{.State.ExitCode}}')
        echo "✅ Container completed with exit code: ${EXIT_CODE}"
        
        # Show final logs if not already following
        if [ "${FOLLOW_LOGS:-true}" != "true" ]; then
            echo "📋 Final container logs:"
            $DOCKER_CMD logs --tail 50 ${CONTAINER_NAME}
        fi
        
        # Send logs to CloudWatch if enabled
        if [ "${SEND_LOGS_TO_CLOUDWATCH:-false}" = "true" ]; then
            # Get instance ID for log stream naming
            INSTANCE_ID=$(curl -s --connect-timeout 5 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown")
            echo "📤 Attempting to send logs to CloudWatch..."
            if send_logs_to_cloudwatch "$LOG_FILE" "${CLOUDWATCH_LOG_GROUP}" "$INSTANCE_ID"; then
                echo "✅ CloudWatch logging completed successfully"
            else
                echo "⚠️ CloudWatch logging failed, but continuing with cleanup"
            fi
        fi
        
        # Update final status
        cat > "/tmp/container_status.json" << EOF
{
    "status": "completed",
    "pid": $$,
    "container_id": "$CONTAINER_ID",
    "exit_code": $EXIT_CODE,
    "end_time": "$(date -Iseconds)",
    "cloudwatch_logs": "${SEND_LOGS_TO_CLOUDWATCH:-false}"
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
        rm -f "$LOCK_FILE"
        
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
        
        # Emergency fallback: If auto-shutdown fails, force shutdown after 2 minutes
        echo "⏰ Setting emergency shutdown timer (2 minutes) in case auto-shutdown fails..."
        (
            sleep 120  # 2 minutes
            echo "🚨 EMERGENCY SHUTDOWN: Auto-shutdown may have failed, forcing shutdown..."
            shutdown_ec2_instance 0
        ) &
        EMERGENCY_PID=$!
        
        # Store emergency PID for cleanup
        echo "$EMERGENCY_PID" > "/tmp/emergency_shutdown.pid"
        
        return $EXIT_CODE
    fi
}

# Main execution function
main() {
    echo "🎬 Starting main execution..."
    
    # Set up trap for cleanup on script termination
    trap 'echo "🚨 Script interrupted, cleaning up..."; rm -f "$LOCK_FILE"; exit 1' INT TERM
    
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

# Execute main function
main "$@"