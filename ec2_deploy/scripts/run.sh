#!/bin/bash

# Updated run.sh - Now includes automatic EC2 shutdown after container completion
# Uses EC2 IAM Role instead of temporary credentials
# FIXED: Better lock file handling and race condition prevention

set -e

# Source utility and function files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/functions.sh"

# Set up logging
LOG_DIR="/tmp/container_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/container_run_$(date +%Y%m%d_%H%M%S).log"

# FIXED: Ultra-simple logging setup that works in both interactive and background modes
# This ensures shell script logs go to the local file
exec > >(tee -a "$LOG_FILE") 2>&1

# Verify logging is working
echo "🔍 Logging setup verification:"
echo "   Log directory: $LOG_DIR"
echo "   Log file: $LOG_FILE"
echo "   Current user: $(whoami)"
echo "   Can write to log file: $(touch "$LOG_FILE" 2>/dev/null && echo "YES" || echo "NO")"
echo "   Log file size: $(wc -c < "$LOG_FILE" 2>/dev/null || echo "0") bytes"

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
echo "🔍 Lock file PID: $LOCK_PID, Current PID: $$"
if [ "$LOCK_PID" = "$$" ]; then
    echo "✅ Lock file verified - we are the authorized process"
else
    echo "⚠️ Lock file PID ($LOCK_PID) differs from our PID ($$)"
    echo "This is normal when started via ssm_starter.sh - proceeding..."
fi

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
        # Try metadata service first with IMDSv2 support, fallback to hardcoded region
        local token
        token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
            --connect-timeout 5 --max-time 10 2>/dev/null)
        
        if [ -n "$token" ]; then
            # Use token to get region
            REGION=$(curl -s -H "X-aws-ec2-metadata-token: $token" \
                http://169.254.169.254/latest/meta-data/placement/region \
                --connect-timeout 5 --max-time 10 2>/dev/null || echo "us-east-2")
        else
            # Fallback to IMDSv1
            REGION=$(curl -s --connect-timeout 5 --max-time 10 \
                http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-2")
        fi
        
        # Validate region format (should be like us-east-2, not HTML)
        if [[ ! "$REGION" =~ ^[a-z]+-[a-z]+-[0-9]+$ ]]; then
            echo "⚠️ Invalid region from metadata, using hardcoded region"
            REGION="us-east-2"
        fi
    fi
    
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    
    # Set defaults
    export REPO_NAME="${REPO_NAME:-ec2-docker-image}"  # Use the correct ECR repository name
    export CONTAINER_NAME="${CONTAINER_NAME:-lol_data_container}"  # Use the value from ec2.env
    export WAIT_FOR_EXIT="${WAIT_FOR_EXIT:-true}"
    export AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
    export CLEANUP_VOLUMES="${CLEANUP_VOLUMES:-false}"
    export AUTO_SHUTDOWN="${AUTO_SHUTDOWN:-true}"
    export SEND_LOGS_TO_CLOUDWATCH="${SEND_LOGS_TO_CLOUDWATCH:-true}"
    export CLOUDWATCH_LOG_GROUP="${CLOUDWATCH_LOG_GROUP:-/aws/ec2/containers/default}"
    export CLOUDWATCH_RETENTION_DAYS="${CLOUDWATCH_RETENTION_DAYS:-7}"
    
    echo "🔐 Loading sensitive variables from SSM..."

    echo "🔍 Loading ACCOUNT_ID..."
    export AWS_ACCOUNT_ID=$(aws ssm get-parameter --name "ACCOUNT_ID" --with-decryption --query "Parameter.Value" --output text)   
    echo "🔍 Loading API_KEY..."
    export API_KEY=$(aws ssm get-parameter --name "API_KEY" --with-decryption --query "Parameter.Value" --output text)
    echo "🔍 Loading API_KEY_EXPIRATION..."
    export API_KEY_EXPIRATION=$(aws ssm get-parameter --name "API_KEY_EXPIRATION" --with-decryption --query "Parameter.Value" --output text) 
    echo "🔍 Loading BACKFILL..."
    export BACKFILL=$(aws ssm get-parameter --name "BACKFILL" --query "Parameter.Value" --output text)


    echo "🔍 AWS_ACCOUNT_ID: ${AWS_ACCOUNT_ID:0:10}..." # Show first 10 chars
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        echo "❌ Failed to load AWS_ACCOUNT_ID from SSM"
        handle_error 3 "Unable to retrieve ACCOUNT_ID from SSM"
    fi

    echo "🔍 API_KEY: ${API_KEY:0:10}..." # Show first 10 chars
    if [ -z "$API_KEY" ]; then
        echo "❌ Failed to load API_KEY from SSM"
        handle_error 3 "Unable to retrieve API_KEY from SSM"
    fi

    echo "🔍 API_KEY_EXPIRATION: $API_KEY_EXPIRATION"
    if [ -z "$API_KEY_EXPIRATION" ]; then
        echo "❌ Failed to load API_KEY_EXPIRATION from SSM"
        handle_error 3 "Unable to retrieve API_KEY_EXPIRATION from SSM"
    fi

    echo "🔍 BACKFILL: $BACKFILL"
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
        export PLAYER_LIMIT=10
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
    if ! adjust_window_if_needed "$start_epoch" "$end_epoch"; then
        echo "🛑 Window adjustment triggered shutdown - sending logs before exit"
        
        # CRITICAL: Set BACKFILL=true before shutting down to preserve the window
        echo "🔄 Setting BACKFILL=true to preserve the updated window for retry..."
        if update_ssm_parameter "BACKFILL" "true"; then
            echo "✅ BACKFILL set to true - window will be retried"
        else
            echo "⚠️ Failed to set BACKFILL=true - window may be lost"
        fi
        
        # Send logs to CloudWatch before shutting down
        if [ "${SEND_LOGS_TO_CLOUDWATCH:-false}" = "true" ]; then
            # Get instance ID for log stream naming with IMDSv2 support
            echo "🔍 Getting instance ID from metadata service..."
            local token
            
            # Get IMDSv2 token first
            token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
                -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
                --connect-timeout 5 --max-time 10 2>/dev/null)
            
            if [ -n "$token" ]; then
                # Use token to get instance ID
                INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $token" \
                    http://169.254.169.254/latest/meta-data/instance-id \
                    --connect-timeout 5 --max-time 10 2>/dev/null)
            else
                # Fallback to IMDSv1 (may not work on newer instances)
                INSTANCE_ID=$(curl -s --connect-timeout 5 --max-time 10 \
                    http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
            fi
            
            # Validate instance ID (should be i-xxxxxxxxx format)
            if [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]]; then
                echo "✅ Instance ID retrieved: $INSTANCE_ID"
            else
                echo "⚠️ Failed to get valid instance ID from metadata, trying AWS CLI..."
                
                # Try to get instance ID from AWS CLI
                INSTANCE_ID=$(aws ec2 describe-instances \
                    --filters "Name=instance-state-name,Values=running" \
                    --query 'Reservations[0].Instances[0].InstanceId' \
                    --output text 2>/dev/null)
                
                # Validate the AWS CLI result
                if [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]]; then
                    echo "✅ Instance ID retrieved via AWS CLI: $INSTANCE_ID"
                else
                    echo "⚠️ AWS CLI also failed, using hardcoded value"
                    INSTANCE_ID="i-05b2706eb5c40af2d"  # Hardcoded based on your instance
                fi
            fi
            
            echo "📤 Attempting to send shutdown logs to CloudWatch..."
            echo "🔍 Debug: CLOUDWATCH_LOG_GROUP = '${CLOUDWATCH_LOG_GROUP}'"
            echo "🔍 Debug: SEND_LOGS_TO_CLOUDWATCH = '${SEND_LOGS_TO_CLOUDWATCH}'"
            if send_logs_to_cloudwatch "$LOG_FILE" "${CLOUDWATCH_LOG_GROUP}" "$INSTANCE_ID" "${CLOUDWATCH_LOG_STREAM}"; then
                echo "✅ CloudWatch logging completed successfully before shutdown"
            else
                echo "⚠️ CloudWatch logging failed, but continuing with shutdown"
            fi
        fi
        
        echo "🛑 Exiting script after slowdown trigger"
        exit 0
    fi
    
    # Re-export the potentially updated epochs
    export start_epoch=$(jq -r '.start_epoch' window.json)
    export end_epoch=$(jq -r '.end_epoch' window.json)
    echo "✅ Final epoch window: $start_epoch to $end_epoch"
    
    # Set CloudWatch log stream name early so it's available for error handling
    export CLOUDWATCH_LOG_STREAM="container-${CONTAINER_NAME:-lol_data_container}-${start_epoch}-${end_epoch}"
    echo "📊 CloudWatch log stream will be: ${CLOUDWATCH_LOG_STREAM}"

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
    ENV_VARS="${ENV_VARS} -e CLOUDWATCH_LOG_GROUP=${CLOUDWATCH_LOG_GROUP}"
    ENV_VARS="${ENV_VARS} -e CLOUDWATCH_LOG_STREAM=${CLOUDWATCH_LOG_STREAM}"
    
    # Extra Docker arguments
    EXTRA_ARGS=""
    if [ -n "${DOCKER_RUN_ARGS}" ]; then
        EXTRA_ARGS="${DOCKER_RUN_ARGS}"
        echo "   Extra Docker args: ${EXTRA_ARGS}"
    fi
    
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
    
    # If SLOWDOWN=true, update EventBridge Scheduler to slow cron and reset SLOWDOWN
    if [ "$slowdown" = "true" ]; then
        echo "🔄 SLOWDOWN=true: Updating EventBridge Scheduler to slow cron..."
        local SLOW_CRON="cron(0 10 */2 * ? *)"
        
        # Load LAMBDA_START_EC2_ARN and EBS_ARN from SSM
        local LAMBDA_START_EC2_ARN
        LAMBDA_START_EC2_ARN=$(aws ssm get-parameter --name "LAMBDA_START_EC2_ARN" --query "Parameter.Value" --output text)
        
        local EBS_ARN
        EBS_ARN=$(aws ssm get-parameter --name "EBS_ARN" --query "Parameter.Value" --output text)
        
        # Validate that we have the required ARNs
        if [ -z "$LAMBDA_START_EC2_ARN" ]; then
            echo "❌ ERROR: Failed to load LAMBDA_START_EC2_ARN from SSM"
            return 1
        fi
        
        if [ -z "$EBS_ARN" ]; then
            echo "❌ ERROR: Failed to load EBS_ARN from SSM"
            return 1
        fi
        
        if aws scheduler update-schedule --name "lol-data-pipeline" --schedule-expression "$SLOW_CRON" --flexible-time-window Mode=OFF --target '{"Arn":"'"$LAMBDA_START_EC2_ARN"'","RoleArn":"'"$EBS_ARN"'"}' 2>&1; then
            echo "✅ Updated EventBridge Scheduler to slow cron: $SLOW_CRON"
        else
            echo "❌ Failed to update EventBridge Scheduler to slow cron"
            
            # Try alternative approach - maybe we need to specify the group
            if aws scheduler update-schedule --name "lol-data-pipeline" --group-name "default" --schedule-expression "$SLOW_CRON" --flexible-time-window Mode=OFF --target '{"Arn":"'"$LAMBDA_START_EC2_ARN"'","RoleArn":"'"$EBS_ARN"'"}' 2>&1; then
                echo "✅ Updated EventBridge Scheduler to slow cron (with group): $SLOW_CRON"
            else
                echo "❌ Failed with group specification too"
            fi
        fi
        
        # Reset SLOWDOWN to false
        update_ssm_parameter "SLOWDOWN" "false"
        echo "📊 Reset SLOWDOWN to false"
    fi

    # Configure CloudWatch logging - Use epoch format for both shell script and container
    CLOUDWATCH_LOG_GROUP="${CLOUDWATCH_LOG_GROUP:-/aws/ec2/containers/lol_data_container}"
    # CLOUDWATCH_LOG_STREAM is already set earlier in the script
    
    # Build Docker run command with conditional CloudWatch logging
    DOCKER_CMD_ARGS="--name ${CONTAINER_NAME} -d ${PORT_MAPPING} ${VOLUME_MAPPING} ${ENV_VARS} ${EXTRA_ARGS}"
    
    # Add CloudWatch logging if enabled
    if [ "${ENABLE_CLOUDWATCH_LOGS:-false}" = "true" ]; then
        DOCKER_CMD_ARGS="${DOCKER_CMD_ARGS} --log-driver=awslogs --log-opt awslogs-group=${CLOUDWATCH_LOG_GROUP} --log-opt awslogs-region=${REGION} --log-opt awslogs-stream=${CLOUDWATCH_LOG_STREAM}"
        echo "📊 CloudWatch logging enabled: ${CLOUDWATCH_LOG_GROUP}/${CLOUDWATCH_LOG_STREAM}"
        echo "📝 Note: Container logs will go to CloudWatch, shell script logs remain in: $LOG_FILE"
    else
        echo "📊 CloudWatch logging disabled"
        echo "📝 Note: All logs (container + shell script) will go to: $LOG_FILE"
    fi
    
    # Show the Docker command being executed
    echo "🔍 Running Docker command:"
    echo "$DOCKER_CMD run ${DOCKER_CMD_ARGS} ${ECR_URI}"
    echo "📝 Shell script logs are being written to: $LOG_FILE"
    echo "📊 Container logs will go to CloudWatch: ${CLOUDWATCH_LOG_GROUP}/${CLOUDWATCH_LOG_STREAM}"

    # Run container with IAM role and conditional CloudWatch logging
    echo "🏃 Starting Docker container: ${CONTAINER_NAME}"
    CONTAINER_ID=$($DOCKER_CMD run ${DOCKER_CMD_ARGS} "${ECR_URI}")
    
    if [ $? -eq 0 ]; then
        echo "✅ Container started with ID: ${CONTAINER_ID}"
        
        # Verify shell script logging is still working
        echo "🔍 Verifying shell script logging after container start:"
        echo "   Log file: $LOG_FILE"
        echo "   Log file size: $(wc -c < "$LOG_FILE" 2>/dev/null || echo "0") bytes"
        echo "   Can still write to log file: $(echo "Test log entry" >> "$LOG_FILE" 2>/dev/null && echo "YES" || echo "NO")"
        
        # Wait a moment for container to initialize
        sleep 3
        
        # Check if container is still running
        if ! $DOCKER_CMD ps -q -f "name=${CONTAINER_NAME}" | grep -q .; then
            echo "❌ Container stopped immediately after starting!"
            echo "🔍 Container logs:"
            $DOCKER_CMD logs "${CONTAINER_NAME}"
            echo "🔍 Container exit code:"
            EXIT_CODE=$($DOCKER_CMD inspect "${CONTAINER_NAME}" --format='{{.State.ExitCode}}')
            echo "Container exit code: $EXIT_CODE"
            
            # CRITICAL: Set BACKFILL=true before shutting down to preserve the window
            echo "🔄 Container failed immediately - setting BACKFILL=true to preserve window..."
            if update_ssm_parameter "BACKFILL" "true"; then
                echo "✅ BACKFILL set to true - window will be retried"
            else
                echo "⚠️ Failed to set BACKFILL=true - window may be lost"
            fi
            
            # Handle exit logic before shutting down
            echo "🔄 Processing container exit logic..."
            handle_exit_logic "$EXIT_CODE"
            
            # Send logs to CloudWatch before exiting
            if [ "${SEND_LOGS_TO_CLOUDWATCH:-false}" = "true" ]; then
                # Get instance ID for log stream naming with IMDSv2 support
                echo "🔍 Getting instance ID from metadata service..."
                local token
                
                # Get IMDSv2 token first
                token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
                    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
                    --connect-timeout 5 --max-time 10 2>/dev/null)
                
                if [ -n "$token" ]; then
                    # Use token to get instance ID
                    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $token" \
                        http://169.254.169.254/latest/meta-data/instance-id \
                        --connect-timeout 5 --max-time 10 2>/dev/null)
                else
                    # Fallback to IMDSv1 (may not work on newer instances)
                    INSTANCE_ID=$(curl -s --connect-timeout 5 --max-time 10 \
                        http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
                fi
                
                # Validate instance ID (should be i-xxxxxxxxx format)
                if [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]]; then
                    echo "✅ Instance ID retrieved: $INSTANCE_ID"
                else
                    echo "⚠️ Failed to get valid instance ID from metadata, trying AWS CLI..."
                    
                    # Try to get instance ID from AWS CLI
                    INSTANCE_ID=$(aws ec2 describe-instances \
                        --filters "Name=instance-state-name,Values=running" \
                        --query 'Reservations[0].Instances[0].InstanceId' \
                        --output text 2>/dev/null)
                    
                    # Validate the AWS CLI result
                    if [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]]; then
                        echo "✅ Instance ID retrieved via AWS CLI: $INSTANCE_ID"
                    else
                        echo "⚠️ AWS CLI also failed, using hardcoded value"
                        INSTANCE_ID="i-05b2706eb5c40af2d"  # Hardcoded based on your instance
                    fi
                fi
                
                echo "📤 Attempting to send immediate failure logs to CloudWatch..."
                echo "🔍 Debug: CLOUDWATCH_LOG_GROUP = '${CLOUDWATCH_LOG_GROUP}'"
                echo "🔍 Debug: SEND_LOGS_TO_CLOUDWATCH = '${SEND_LOGS_TO_CLOUDWATCH}'"
                if send_logs_to_cloudwatch "$LOG_FILE" "${CLOUDWATCH_LOG_GROUP}" "$INSTANCE_ID" "${CLOUDWATCH_LOG_STREAM}"; then
                    echo "✅ CloudWatch logging completed successfully before exit"
                else
                    echo "⚠️ CloudWatch logging failed, but continuing with exit"
                fi
            fi
            
            # Clean up lock file before exiting
            rm -f "$LOCK_FILE"
            
            # Shutdown EC2 instance before exiting
            echo "🛑 Container failed immediately, shutting down EC2 instance..."
            shutdown_ec2_instance 10  # 10 second delay to allow logs to be written
            
            # Exit with the container's exit code
            echo "🛑 Exiting script with code $EXIT_CODE"
            exit "$EXIT_CODE"
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
        
            # Wait for container to exit with reasonable monitoring for long-running containers
    echo "🔍 Monitoring container status..."
    local check_count=0
    local check_interval=30  # Start with 30 seconds
    
    while true; do
        # Check if container is still running
        if ! $DOCKER_CMD ps -q -f "name=${CONTAINER_NAME}" | grep -q .; then
            echo "✅ Container has completed"
            break
        fi
        
        # Increment check count and adjust interval for long-running containers
        check_count=$((check_count + 1))
        
        # Adjust check interval based on how long we've been waiting
        if [ $check_count -gt 120 ]; then  # After 1 hour, check every 5 minutes
            check_interval=300
        elif [ $check_count -gt 60 ]; then  # After 30 minutes, check every 2 minutes
            check_interval=120
        elif [ $check_count -gt 20 ]; then  # After 10 minutes, check every minute
            check_interval=60
        fi
        
        # Show progress every 10 checks
        if [ $((check_count % 10)) -eq 0 ]; then
            echo "⏳ Still waiting for container completion... (check $check_count, interval ${check_interval}s)"
        fi
        
        sleep $check_interval
    done
        
        # Get final status
        EXIT_CODE=$($DOCKER_CMD inspect ${CONTAINER_NAME} --format='{{.State.ExitCode}}')
        echo "✅ Container completed with exit code: ${EXIT_CODE}"
        
        # Handle exit logic based on container exit code
        echo "🔄 Processing container exit logic..."
        handle_exit_logic "$EXIT_CODE"
        
        # Capture container logs to file (silently to avoid duplication)
        CONTAINER_LOG_FILE="$LOG_DIR/container_logs_$(date +%Y%m%d_%H%M%S).log"
        echo "📋 Capturing container logs to: $CONTAINER_LOG_FILE"
        $DOCKER_CMD logs ${CONTAINER_NAME} > "$CONTAINER_LOG_FILE" 2>&1
        
        # Show final logs summary (just the count, not the content to avoid duplication)
        echo "📋 Container logs captured: $(wc -l < "$CONTAINER_LOG_FILE") lines"
        
        # Send logs to CloudWatch if enabled
        if [ "${SEND_LOGS_TO_CLOUDWATCH:-false}" = "true" ]; then
            # Get instance ID for log stream naming with IMDSv2 support
            echo "🔍 Getting instance ID from metadata service..."
            local token
            
            # Get IMDSv2 token first
            token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
                -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
                --connect-timeout 5 --max-time 10 2>/dev/null)
            
            if [ -n "$token" ]; then
                # Use token to get instance ID
                INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $token" \
                    http://169.254.169.254/latest/meta-data/instance-id \
                    --connect-timeout 5 --max-time 10 2>/dev/null)
            else
                # Fallback to IMDSv1 (may not work on newer instances)
                INSTANCE_ID=$(curl -s --connect-timeout 5 --max-time 10 \
                    http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
            fi
            
            # Validate instance ID (should be i-xxxxxxxxx format)
            if [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]]; then
                echo "✅ Instance ID retrieved: $INSTANCE_ID"
            else
                echo "⚠️ Failed to get valid instance ID from metadata, trying AWS CLI..."
                
                # Try to get instance ID from AWS CLI
                INSTANCE_ID=$(aws ec2 describe-instances \
                    --filters "Name=instance-state-name,Values=running" \
                    --query 'Reservations[0].Instances[0].InstanceId' \
                    --output text 2>/dev/null)
                
                # Validate the AWS CLI result
                if [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]]; then
                    echo "✅ Instance ID retrieved via AWS CLI: $INSTANCE_ID"
                else
                    echo "⚠️ AWS CLI also failed, using hardcoded value"
                    INSTANCE_ID="i-05b2706eb5c40af2d"  # Hardcoded based on your instance
                fi
            fi
            
            # Create combined log file with both shell script and container logs
            COMBINED_LOG_FILE="$LOG_DIR/combined_logs_$(date +%Y%m%d_%H%M%S).log"
            echo "📋 Creating combined log file: $COMBINED_LOG_FILE"
            
            # Add shell script logs first
            echo "=== SHELL SCRIPT LOGS ===" > "$COMBINED_LOG_FILE"
            cat "$LOG_FILE" >> "$COMBINED_LOG_FILE"
            
            # Add container logs
            echo "" >> "$COMBINED_LOG_FILE"
            echo "=== CONTAINER LOGS ===" >> "$COMBINED_LOG_FILE"
            cat "$CONTAINER_LOG_FILE" >> "$COMBINED_LOG_FILE"
            
            echo "📤 Attempting to send combined logs to CloudWatch..."
            echo "🔍 Debug: CLOUDWATCH_LOG_GROUP = '${CLOUDWATCH_LOG_GROUP}'"
            echo "🔍 Debug: SEND_LOGS_TO_CLOUDWATCH = '${SEND_LOGS_TO_CLOUDWATCH}'"
            if send_logs_to_cloudwatch "$COMBINED_LOG_FILE" "${CLOUDWATCH_LOG_GROUP}" "$INSTANCE_ID" "${CLOUDWATCH_LOG_STREAM}"; then
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
        
        # Wait a moment for the shutdown to be processed
        sleep 5
        
        return $EXIT_CODE
    fi
}

# Main execution function
main() {
    echo "🎬 Starting main execution..."
    
    # Set up trap for cleanup on script termination
    trap 'echo "🚨 Script interrupted, cleaning up..."; rm -f "$LOCK_FILE"; exit 1' INT TERM
    
    # Set Docker command based on user permissions
    if groups | grep -q docker; then
        DOCKER_CMD="docker"
    else
        DOCKER_CMD="sudo docker"
    fi
    export DOCKER_CMD
    
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