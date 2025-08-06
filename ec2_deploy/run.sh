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
    
    # Create log stream name with timestamp and validated instance ID
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local log_stream="container-${timestamp}-${instance_id}"
    
    # Ensure log stream name is valid (no special characters)
    log_stream=$(echo "$log_stream" | sed 's/[^a-zA-Z0-9_-]//g')
    
    echo "📝 Creating log stream: $log_stream"
    
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
        local current_timestamp=$(date +%s)000
        
        # Create the log events file in the correct format for put-log-events
        # The format should be: [{"timestamp": 1234567890000, "message": "log message"}]
        echo "[" > "$temp_events_file"
        local first_line=true
        local line_count=0
        
        while IFS= read -r line; do
            # Skip empty lines
            [ -z "$line" ] && continue
            
            # Escape quotes and backslashes in the message
            escaped_line=$(echo "$line" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
            
            if [ "$first_line" = true ]; then
                first_line=false
            else
                echo "," >> "$temp_events_file"
            fi
            
            echo "{\"timestamp\": $current_timestamp, \"message\": \"$escaped_line\"}" >> "$temp_events_file"
            ((line_count++))
        done < "$log_file"
        
        echo "]" >> "$temp_events_file"
        
        # Check if we have any content
        if [ "$line_count" -eq 0 ]; then
            echo "⚠️ No log content to upload"
            rm -f "$temp_events_file"
            return 0
        fi
        
        # Validate JSON format
        if ! python3 -m json.tool "$temp_events_file" > /dev/null 2>&1; then
            echo "❌ Invalid JSON format generated"
            echo "📋 Debug: JSON file content (first 10 lines):"
            head -10 "$temp_events_file"
            rm -f "$temp_events_file"
            return 1
        fi
        
        # Upload to CloudWatch using the correct format
        aws logs put-log-events \
            --log-group-name "$log_group" \
            --log-stream-name "$log_stream" \
            --log-events file://"$temp_events_file" || {
            echo "⚠️ Failed to upload logs to CloudWatch"
            echo "📋 Debug: JSON file content (first 10 lines):"
            head -10 "$temp_events_file"
            rm -f "$temp_events_file"
            return 1
        }
        
        rm -f "$temp_events_file"
        
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
        --connect-timeout 5 --max-time 10 --silent) || {
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
    
    # Load ec2.env from the deployment location
    if [ -f "/home/ec2-user/ec2.env" ]; then
        set -o allexport
        source /home/ec2-user/ec2.env
        set +o allexport
        echo "✅ Environment variables loaded from /home/ec2-user/ec2.env"
    else
        echo "⚠️ ec2.env file not found at /home/ec2-user/ec2.env, using defaults and environment"
    fi
    
    # Get region from instance metadata
    if [ -z "$REGION" ]; then
        echo "🔍 Getting region from instance metadata..."
        REGION=$(curl -s --connect-timeout 5 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")
    fi
    
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    
    # Set defaults
    export REPO_NAME="${REPO_NAME:-lol_data_project}"  # Use a consistent default instead of relying on GitHub vars
    export CONTAINER_NAME="${CONTAINER_NAME:-lol_data_container}"  # Use the value from ec2.env
    export WAIT_FOR_EXIT="${WAIT_FOR_EXIT:-true}"
    export AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
    export CLEANUP_VOLUMES="${CLEANUP_VOLUMES:-false}"
    export AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-true}"
    export SEND_LOGS_TO_CLOUDWATCH="${SEND_LOGS_TO_CLOUDWATCH:-false}"
    export CLOUDWATCH_LOG_GROUP="${CLOUDWATCH_LOG_GROUP:-/aws/ec2/containers/default}"
    export CLOUDWATCH_RETENTION_DAYS="${CLOUDWATCH_RETENTION_DAYS:-7}"
    
    echo "🔐 Loading sensitive variables from SSM..."

    export AWS_ACCOUNT_ID=$(aws ssm get-parameter --name "ACCOUNT_ID" --with-decryption --query "Parameter.Value" --output text)   
    export API_KEY=$(aws ssm get-parameter --name "API_KEY" --with-decryption --query "Parameter.Value" --output text)
    export API_KEY_EXPIRATION=$(aws ssm get-parameter --name "API_KEY_EXPIRATION" --with-decryption --query "Parameter.Value" --output text) 
    export BACKFILL=$(aws ssm get-parameter --name "BACKFILL" --query "Parameter.Value" --output text)

    if [ -z "$AWS_ACCOUNT_ID" ]; then
        echo "❌ Failed to load AWS_ACCOUNT_ID from SSM"
        handle_error 3 "Unable to retrieve ACCOUNT_ID from SSM"
    fi

    if [ -z "$API_KEY" ]; then
        echo "❌ Failed to load API_KEY from SSM"
        handle_error 3 "Unable to retrieve API_KEY from SSM"
    fi

    if [ -z "$API_KEY_EXPIRATION" ]; then
        echo "❌ Failed to load API_KEY_EXPIRATION from SSM"
        handle_error 3 "Unable to retrieve API_KEY_EXPIRATION from SSM"
    fi

    if [ -z "$BACKFILL" ]; then
        echo "❌ Failed to load BACKFILL from SSM"
        handle_error 3 "Unable to retrieve BACKFILL from SSM"
    fi

    # Validate required variables
    if [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$REGION" ] || [ -z "$REPO_NAME" ] || [ -z "$API_KEY" ] || [ -z "$API_KEY_EXPIRATION" ]; then
        handle_error 2 "Missing required variables (AWS_ACCOUNT_ID, REGION, REPO_NAME, API_KEY, API_KEY_EXPIRATION)"
    fi
    
    # Determine RUN_MODE and set corresponding variables
    if [ "${RUN_MODE}" == "test" ]; then
        export PLAYER_LIMIT=100
        export SOURCE='test'
    else
        export PLAYER_LIMIT=100000
        export SOURCE='prod'
    fi 

    # Determine epoch S3 path based on BACKFILL setting
    if [ "$BACKFILL" = "true" ]; then
        EPOCH_S3_PATH="$BACKFILL_STATE_JSON_PATH"
        echo "📅 Using backfill mode - loading epochs from: $EPOCH_S3_PATH"
    else
        EPOCH_S3_PATH="$PROD_STATE_JSON_PATH"
        echo "📅 Using production mode - loading epochs from: $EPOCH_S3_PATH"
    fi

    # Download and parse epoch window from S3
    echo "📥 Downloading epoch window from S3..."
    aws s3 cp "$EPOCH_S3_PATH" ./window.json || {
        echo "❌ Failed to download epoch window from S3"
        handle_error 4 "Unable to download epoch window from $EPOCH_S3_PATH"
    }

    # Extract start and end epochs from the JSON
    export start_epoch=$(jq -r '.start_epoch' window.json)
    export end_epoch=$(jq -r '.end_epoch' window.json)

    # Validate epoch values
    if [ -z "$start_epoch" ] || [ "$start_epoch" = "null" ] || [ -z "$end_epoch" ] || [ "$end_epoch" = "null" ]; then
        echo "❌ Failed to extract valid epochs from window.json"
        echo "📋 Window.json contents:"
        cat window.json
        handle_error 5 "Invalid epoch values in window.json"
    fi

    echo "✅ Epoch window loaded: $start_epoch to $end_epoch"
    
    # Handle window adjustment based on BACKFILL and ACCELERATE settings
    echo "🔄 Checking window adjustment logic..."
    adjust_window_if_needed "$start_epoch" "$end_epoch"
    
    # Re-export the potentially updated epochs
    export start_epoch=$(jq -r '.start_epoch' window.json)
    export end_epoch=$(jq -r '.end_epoch' window.json)
    echo "✅ Final epoch window: $start_epoch to $end_epoch"

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
    
    # Pass essential variables to container
    ENV_VARS="${ENV_VARS} -e AWS_DEFAULT_REGION=${REGION}"
    ENV_VARS="${ENV_VARS} -e AWS_REGION=${REGION}"
    ENV_VARS="${ENV_VARS} -e PLAYER_LIMIT=${PLAYER_LIMIT}"
    ENV_VARS="${ENV_VARS} -e BUCKET=${BUCKET}"
    ENV_VARS="${ENV_VARS} -e source=${SOURCE}"
    ENV_VARS="${ENV_VARS} -e start_epoch=${start_epoch}"
    ENV_VARS="${ENV_VARS} -e end_epoch=${end_epoch}"
    ENV_VARS="${ENV_VARS} -e API_KEY=${API_KEY}"
    ENV_VARS="${ENV_VARS} -e API_KEY_EXPIRATION=${API_KEY_EXPIRATION}"
    
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

    # Check SLOWDOWN setting before container run
    echo "🔄 Checking SLOWDOWN setting..."
    local slowdown
    if slowdown_response=$(aws ssm get-parameter --name "SLOWDOWN" --query "Parameter.Value" --output text 2>/dev/null); then
        slowdown=$(echo "$slowdown_response" | tr '[:upper:]' '[:lower:]')
        echo "📊 SLOWDOWN setting: $slowdown"
    else
        echo "⚠️ Failed to get SLOWDOWN from SSM, defaulting to false"
        slowdown="false"
    fi
    
    # If SLOWDOWN=true, update EventBridge to slow cron and reset SLOWDOWN
    if [ "$slowdown" = "true" ]; then
        echo "🔄 SLOWDOWN=true: Updating EventBridge to slow cron..."
        local SLOW_CRON="cron(0 10 */2 * ? *)"
        if aws events put-rule --name "lol-data-pipeline-schedule" --schedule-expression "$SLOW_CRON" >/dev/null 2>&1; then
            echo "✅ Updated EventBridge to slow cron: $SLOW_CRON"
        else
            echo "❌ Failed to update EventBridge to slow cron"
        fi
        
        # Reset SLOWDOWN to false
        update_ssm_parameter "SLOWDOWN" "false"
        echo "📊 Reset SLOWDOWN to false"
    fi

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
        # Always follow logs for real-time monitoring
        echo "📋 Following container logs in background..."
        $DOCKER_CMD logs -f ${CONTAINER_NAME} &
        LOGS_PID=$!
        fi
        
        # Wait for container to exit with reasonable monitoring for long-running containers
        echo "🔍 Monitoring container status..."
        local check_count=0
        local check_interval=30  # Start with 30 seconds
        local log_interval=120   # Log status every 2 minutes initially
        local next_log_time=0
        
        while true; do
            if ! $DOCKER_CMD ps -q -f "name=${CONTAINER_NAME}" | grep -q .; then
                echo "✅ Container has exited"
                break
            fi
            
            ((check_count++))
            local current_time=$(date +%s)
            
            # Log status at reasonable intervals
            if [ "$current_time" -ge "$next_log_time" ]; then
                local runtime_minutes=$((check_count * check_interval / 60))
                if [ "$runtime_minutes" -lt 60 ]; then
                    echo "⏱️ Container still running (${runtime_minutes}m) at $(date '+%H:%M:%S')"
                    next_log_time=$((current_time + log_interval))  # Every 2 minutes for first hour
                else
                    local runtime_hours=$((runtime_minutes / 60))
                    echo "⏱️ Container still running (${runtime_hours}h ${runtime_minutes}m) at $(date '+%H:%M:%S')"
                    next_log_time=$((current_time + 900))  # Every 15 minutes after first hour
                fi
                
                # Increase intervals for very long runs
                if [ "$runtime_minutes" -gt 180 ]; then  # After 3 hours
                    check_interval=60     # Check every minute
                    log_interval=1800     # Log every 30 minutes
                fi
            fi
            
            sleep "$check_interval"
        done
        
        # Kill log following process if it's still running
        # Stop log following process
        if [ -n "$LOGS_PID" ]; then
            echo "📋 Stopping log following process..."
            kill $LOGS_PID 2>/dev/null || true
            wait $LOGS_PID 2>/dev/null || true
        fi
        
        # Get final status
            EXIT_CODE=$($DOCKER_CMD inspect ${CONTAINER_NAME} --format='{{.State.ExitCode}}')
    echo "✅ Container completed with exit code: ${EXIT_CODE}"
    
    # Handle exit logic based on container exit code
    echo "🔄 Processing container exit logic..."
    handle_exit_logic "$EXIT_CODE"
        
        # Show final logs if not already following
        # Always show final logs summary since we always follow logs
        echo "📋 Final container logs:"
        $DOCKER_CMD logs --tail 50 ${CONTAINER_NAME}
        
        # Send logs to CloudWatch if enabled
        if [ "${SEND_LOGS_TO_CLOUDWATCH:-false}" = "true" ]; then
            # Get instance ID for log stream naming with better error handling
            echo "🔍 Getting instance ID from metadata service..."
            INSTANCE_ID=$(curl -s --connect-timeout 5 --max-time 10 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
            
            # Validate instance ID (should be i-xxxxxxxxx format)
            if [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]]; then
                echo "✅ Instance ID retrieved: $INSTANCE_ID"
            else
                echo "⚠️ Failed to get valid instance ID, using timestamp instead"
                INSTANCE_ID="unknown-$(date +%Y%m%d-%H%M%S)"
            fi
            
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

# Function to update SSM parameter
update_ssm_parameter() {
    local parameter_name="$1"
    local value="$2"
    
    echo "🔄 Updating SSM parameter $parameter_name to $value..."
    if aws ssm put-parameter --name "$parameter_name" --value "$value" --type "String" --overwrite >/dev/null 2>&1; then
        echo "✅ Updated SSM parameter $parameter_name to $value"
        return 0
    else
        echo "❌ Failed to update SSM parameter $parameter_name"
        return 1
    fi
}

# Function to update window.json and upload to S3
update_window_json() {
    local start_epoch="$1"
    local end_epoch="$2"
    local s3_path="$3"
    
    echo "🔄 Updating window.json at $s3_path..."
    
    # Extract bucket and key from s3://bucket/path
    local bucket=$(echo "$s3_path" | sed 's|s3://||' | cut -d'/' -f1)
    local key=$(echo "$s3_path" | sed 's|s3://[^/]*/||')
    
    # Create window data JSON
    local window_data="{\"start_epoch\":$start_epoch,\"end_epoch\":$end_epoch}"
    
    if echo "$window_data" | aws s3 cp - "s3://$bucket/$key" --content-type "application/json" >/dev/null 2>&1; then
        echo "✅ Updated window.json at $s3_path: $start_epoch to $end_epoch"
        return 0
    else
        echo "❌ Failed to update window.json at $s3_path"
        return 1
    fi
}

# Function to adjust window based on BACKFILL and ACCELERATE settings
adjust_window_if_needed() {
    local start_epoch="$1"
    local end_epoch="$2"
    
    # Hardcoded CRON expressions
    local FAST_CRON="cron(0 10 * * ? *)"
    local SLOW_CRON="cron(0 10 */2 * ? *)"
    
    echo "🔄 Checking window adjustment logic..."
    
    # Get current BACKFILL setting from SSM
    local backfill
    if backfill_response=$(aws ssm get-parameter --name "BACKFILL" --query "Parameter.Value" --output text 2>/dev/null); then
        backfill=$(echo "$backfill_response" | tr '[:upper:]' '[:lower:]')
        echo "📊 BACKFILL setting: $backfill"
    else
        echo "⚠️ Failed to get BACKFILL from SSM, defaulting to false"
        backfill="false"
    fi
    
    # If BACKFILL=true, keep current window and run container
    if [ "$backfill" = "true" ]; then
        echo "🔄 BACKFILL=true: Using current window $start_epoch to $end_epoch"
        return
    fi
    
    # BACKFILL=false - Check FORCE_FAST first
    echo "🚀 BACKFILL=false: Checking FORCE_FAST setting..."
    
    # Get current FORCE_FAST setting from SSM
    local force_fast
    if force_fast_response=$(aws ssm get-parameter --name "FORCE_FAST" --query "Parameter.Value" --output text 2>/dev/null); then
        force_fast=$(echo "$force_fast_response" | tr '[:upper:]' '[:lower:]')
        echo "⚡ FORCE_FAST setting: $force_fast"
    else
        echo "⚠️ Failed to get FORCE_FAST from SSM, defaulting to false"
        force_fast="false"
    fi
    
    # If FORCE_FAST=true, update EventBridge to fast cron and continue
    if [ "$force_fast" = "true" ]; then
        echo "🚀 FORCE_FAST=true: Updating EventBridge to fast cron..."
        if aws events put-rule --name "lol-data-pipeline" --schedule-expression "$FAST_CRON" >/dev/null 2>&1; then
            echo "✅ Updated EventBridge to fast cron: $FAST_CRON"
        else
            echo "❌ Failed to update EventBridge to fast cron"
        fi
    fi
    
    # BACKFILL=false - Check ACCELERATE and adjust window
    echo "🚀 BACKFILL=false: Checking ACCELERATE setting..."
    
    # Get current ACCELERATE setting from SSM
    local accelerate
    if accelerate_response=$(aws ssm get-parameter --name "ACCELERATE" --query "Parameter.Value" --output text 2>/dev/null); then
        accelerate=$(echo "$accelerate_response" | tr '[:upper:]' '[:lower:]')
        echo "⚡ ACCELERATE setting: $accelerate"
    else
        echo "⚠️ Failed to get ACCELERATE from SSM, defaulting to false"
        accelerate="false"
    fi
    
    local current_start="$start_epoch"
    local current_end="$end_epoch"
    local current_time=$(date +%s)
    
    # Loop for epoch adjustment
    local max_iterations=10  # Prevent infinite loops
    local iteration=0
    
    while [ $iteration -lt $max_iterations ]; do
        iteration=$((iteration + 1))
        echo "🔄 Window adjustment iteration $iteration"
        
        # Calculate new epochs
        local new_start="$current_end"
        local new_end
        
        if [ "$accelerate" = "true" ]; then
            new_end=$((current_end + 4 * 24 * 3600))  # +4 days
            echo "⚡ Accelerated mode: $new_start to $new_end (+4 days)"
        else
            new_end=$((current_end + 2 * 24 * 3600))  # +2 days
            echo "🐌 Normal mode: $new_start to $new_end (+2 days)"
        fi
        
        # Check if new end_epoch is greater than current time
        if [ $new_end -gt $current_time ]; then
            if [ "$accelerate" = "true" ]; then
                # Switch to normal mode and recalculate
                echo "⚠️ New end_epoch ($new_end) > current_time ($current_time) with ACCELERATE=true"
                echo "🔄 Switching to normal mode and recalculating..."
                update_ssm_parameter "ACCELERATE" "false"
                accelerate="false"
                current_end="$new_end"  # Use the calculated end as new start
                continue
            else
                # Normal mode but still too far ahead - trigger slowdown
                echo "⚠️ New end_epoch ($new_end) > current_time ($current_time) with ACCELERATE=false"
                echo "🔄 Triggering slowdown mode..."
                
                # Set SLOWDOWN=true and FORCE_FAST=false
                update_ssm_parameter "SLOWDOWN" "true"
                update_ssm_parameter "FORCE_FAST" "false"
                
                echo "📊 Set SLOWDOWN=true, FORCE_FAST=false"
                echo "🛑 Shutting down EC2 instance to allow window to catch up..."
                
                # Shutdown EC2 instance
                shutdown_ec2_instance 30
                return
            fi
        else
            # New end_epoch is in the past - safe to update
            echo "✅ New end_epoch ($new_end) <= current_time ($current_time) - safe to update"
            update_window_json "$new_start" "$new_end" "s3://lol-match-jsons/production/state/next_window.json"
            return
        fi
    done
    
    # If we reach here, we hit max iterations
    echo "⚠️ Hit maximum iterations ($max_iterations), using last calculated window"
    update_window_json "$new_start" "$new_end" "s3://lol-match-jsons/production/state/next_window.json"
}

# Function to handle exit logic based on exit code
handle_exit_logic() {
    local exit_code="$1"
    
    echo "🔄 Processing exit code $exit_code..."
    
    # Set BACKFILL and ACCELERATE based on exit code
    local backfill_value
    local accelerate_value
    
    if [ "$exit_code" = "0" ] || [ "$exit_code" = "7" ] || [ "$exit_code" = "8" ]; then
        # Success or non-critical failures - move to production
        backfill_value="false"
        echo "📊 Exit code $exit_code: Setting BACKFILL=false (ACCELERATE unchanged)"
    elif [ "$exit_code" = "1" ]; then
        # Critical failure - stay in backfill and accelerate
        backfill_value="true"
        accelerate_value="true"
        echo "📊 Exit code $exit_code: Setting BACKFILL=true, ACCELERATE=true (catch-up mode)"
    else
        echo "⚠️ Unknown exit code $exit_code, defaulting to production"
        backfill_value="false"
    fi
    
    # Update BACKFILL SSM parameter
    update_ssm_parameter "BACKFILL" "$backfill_value"
    
    # Only update ACCELERATE if we're setting it to true (backfill mode)
    if [ "$exit_code" = "1" ]; then
        update_ssm_parameter "ACCELERATE" "$accelerate_value"
    fi
    
    echo "✅ Exit logic completed - BACKFILL=$backfill_value, ACCELERATE=$accelerate_value"
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