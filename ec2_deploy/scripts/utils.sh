#!/bin/bash

# Utility functions for EC2 container orchestration
# This file contains AWS operations, validation, and cleanup functions

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
            echo "⚠️ Failed to create CloudWatch log group, continuing without CloudWatch logging"
            return 1
        }
    fi
    
    # Create log stream
    echo "📝 Creating CloudWatch log stream: $log_stream"
    if aws logs create-log-stream --log-group-name "$log_group" --log-stream-name "$log_stream" >/dev/null 2>&1; then
        echo "✅ Log stream created: $log_stream"
    else
        echo "⚠️ Failed to create CloudWatch log stream, continuing without CloudWatch logging"
        return 1
    fi
    
    # Upload log file to CloudWatch
    echo "📤 Uploading log file to CloudWatch..."
    if aws logs put-log-events \
        --log-group-name "$log_group" \
        --log-stream-name "$log_stream" \
        --log-events file://<(cat "$log_file" | jq -R -s 'split("\n")[:-1] | map({timestamp: (now * 1000 | floor), message: .})') >/dev/null 2>&1; then
        echo "✅ Logs uploaded to CloudWatch successfully"
        return 0
    else
        echo "⚠️ Failed to upload logs to CloudWatch"
        return 1
    fi
}

# Function to shutdown EC2 instance
shutdown_ec2_instance() {
    local delay_seconds="${1:-30}"
    
    echo "🛑 Initiating EC2 instance shutdown in ${delay_seconds} seconds..."
    
    # Get instance ID
    local instance_id
    instance_id=$(curl -s --connect-timeout 5 --max-time 10 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
    
    # Validate instance ID format (should be i-xxxxxxxxx, not HTML)
    if [[ ! "$instance_id" =~ ^i-[a-f0-9]+$ ]]; then
        echo "⚠️ Invalid instance ID from metadata, using hardcoded value"
        instance_id="i-05b2706eb5c40af2d"  # Hardcoded based on your instance
    fi
    
    if [ -z "$instance_id" ]; then
        echo "⚠️ Could not retrieve instance ID, using alternative shutdown method"
        # Alternative shutdown method
        (
            sleep "$delay_seconds"
            echo "🚨 Emergency shutdown after ${delay_seconds} seconds"
            sudo shutdown -h now
        ) &
        return
    fi
    
    echo "📋 Instance ID: $instance_id"
    
    # Shutdown with delay
    (
        sleep "$delay_seconds"
        echo "🛑 Shutting down EC2 instance: $instance_id"
        
        # Try to terminate the instance gracefully
        if aws ec2 terminate-instances --instance-ids "$instance_id" >/dev/null 2>&1; then
            echo "✅ Instance termination initiated successfully"
        else
            echo "⚠️ Failed to terminate instance via AWS CLI, using system shutdown"
            sudo shutdown -h now
        fi
    ) &
    
    echo "⏰ Shutdown timer started (${delay_seconds}s delay)"
}

# Function to check Docker availability
check_docker() {
    echo "🔍 Checking Docker availability..."
    
    if ! command -v docker >/dev/null 2>&1; then
        handle_error 1 "Docker is not installed or not in PATH"
    fi
    
    # Use DOCKER_CMD if set, otherwise default to docker
    local docker_cmd="${DOCKER_CMD:-docker}"
    
    if ! $docker_cmd version >/dev/null 2>&1; then
        handle_error 2 "Docker is not running or not accessible"
    fi
    
    echo "✅ Docker is available and running"
    
    # Check Docker daemon
    if ! $docker_cmd info >/dev/null 2>&1; then
        handle_error 2 "Cannot connect to Docker daemon"
    fi
    
    echo "✅ Docker daemon is accessible"
}

# Function to verify IAM credentials
verify_iam_credentials() {
    echo "🔐 Verifying IAM role credentials..."
    
    # Check if we can access AWS services
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        handle_error 3 "Cannot access AWS services - IAM role may not be properly configured"
    fi
    
    # Get caller identity for logging
    local caller_identity
    caller_identity=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
    
    if [ -n "$caller_identity" ]; then
        echo "✅ IAM credentials verified: $caller_identity"
    else
        echo "⚠️ Could not retrieve caller identity, but AWS access confirmed"
    fi
    
    # Test specific permissions we need
    echo "🔍 Testing required AWS permissions..."
    
    # Test SSM access
    if ! aws ssm describe-parameters --max-items 1 >/dev/null 2>&1; then
        echo "⚠️ Warning: SSM access may be limited"
    else
        echo "✅ SSM access confirmed"
    fi
    
    # Test S3 access
    if ! aws s3 ls >/dev/null 2>&1; then
        echo "⚠️ Warning: S3 access may be limited"
    else
        echo "✅ S3 access confirmed"
    fi
    
    # Test ECR access
    if ! aws ecr describe-repositories --max-items 1 >/dev/null 2>&1; then
        echo "⚠️ Warning: ECR access may be limited"
    else
        echo "✅ ECR access confirmed"
    fi
    
    echo "✅ IAM role verification completed"
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