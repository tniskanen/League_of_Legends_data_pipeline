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
    echo "🔍 Debug: Log group name: $log_group"
    echo "🔍 Debug: Instance ID: $instance_id"
    
    # Create log stream name with timestamp and validated instance ID
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local log_stream="container-${timestamp}-${instance_id}"
    
    # Ensure log stream name is valid (no special characters)
    log_stream=$(echo "$log_stream" | sed 's/[^a-zA-Z0-9_-]//g')
    
    echo "📝 Creating log stream: $log_stream"
    
    # Check if log group exists, create if not
    echo "📝 Checking if CloudWatch log group exists: $log_group"
    
    # Debug: Test AWS CLI access
    echo "🔍 Debug: Testing AWS CLI access..."
    if aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null; then
        echo "✅ AWS CLI access confirmed"
    else
        echo "❌ AWS CLI access failed"
        return 1
    fi
    
    # Debug: Check current region
    echo "🔍 Debug: Current AWS region: $(aws configure get region 2>/dev/null || echo 'not set')"
    echo "🔍 Debug: AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
    echo "🔍 Debug: AWS_REGION: $AWS_REGION"
    
    # Try to describe the specific log group
    if aws logs describe-log-groups --log-group-names "$log_group" --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "$log_group"; then
        echo "✅ Log group already exists: $log_group"
    else
        echo "📝 Log group not found with exact name, trying prefix search..."
        
        # Try with prefix search instead
        if aws logs describe-log-groups --log-group-name-prefix "$log_group" --query "logGroups[?logGroupName=='$log_group'].logGroupName" --output text 2>/dev/null | grep -q "$log_group"; then
            echo "✅ Log group already exists (found via prefix search): $log_group"
        else
            echo "📝 Log group not found, attempting to create: $log_group"
        
        # Try to create the log group
        if aws logs create-log-group --log-group-name "$log_group" 2>/dev/null; then
            echo "✅ Log group created successfully: $log_group"
        else
            echo "⚠️ Failed to create CloudWatch log group"
            echo "🔍 Debug: Testing CloudWatch permissions..."
            
            # Test specific CloudWatch permissions
            echo "🔍 Testing logs:CreateLogGroup permission..."
            aws logs create-log-group --log-group-name "/test-permissions-$(date +%s)" 2>&1 | head -1
            
            echo "🔍 Testing logs:DescribeLogGroups permission..."
            aws logs describe-log-groups --max-items 1 2>&1 | head -1
            
            echo "🔍 Testing logs:DescribeLogGroups with prefix..."
            aws logs describe-log-groups --log-group-name-prefix "/aws/ec2/containers/" 2>&1 | head -5
            
            echo "🔍 Checking if log group exists with different method..."
            
            # Try alternative method to check if it exists
            if aws logs describe-log-groups --log-group-name-prefix "$log_group" --query "logGroups[?logGroupName=='$log_group'].logGroupName" --output text 2>/dev/null | grep -q "$log_group"; then
                echo "✅ Log group exists (found via alternative method): $log_group"
            else
                echo "❌ Log group does not exist and could not be created"
                echo "⚠️ This appears to be an IAM permissions issue"
                echo "⚠️ Required permissions: logs:CreateLogGroup, logs:DescribeLogGroups, logs:CreateLogStream, logs:PutLogEvents"
                echo "⚠️ Continuing without CloudWatch logging"
                return 1
            fi
        fi
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
    
    # Check if log file exists and has content
    if [ ! -f "$log_file" ]; then
        echo "❌ Log file not found: $log_file"
        return 1
    fi
    
    if [ ! -s "$log_file" ]; then
        echo "⚠️ Log file is empty: $log_file"
        return 1
    fi
    
    # Create a temporary JSON file for log events
    local temp_json="/tmp/log_events_$(date +%s).json"
    
    # Convert log file to CloudWatch format
    echo "🔍 Converting log file to CloudWatch format..."
    cat "$log_file" | jq -R -s 'split("\n")[:-1] | map({timestamp: (now * 1000 | floor), message: .})' > "$temp_json" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo "❌ Failed to convert log file to JSON format"
        return 1
    fi
    
    # Upload to CloudWatch
    if aws logs put-log-events \
        --log-group-name "$log_group" \
        --log-stream-name "$log_stream" \
        --log-events file://"$temp_json" >/dev/null 2>&1; then
        echo "✅ Logs uploaded to CloudWatch successfully"
        rm -f "$temp_json"
        return 0
    else
        echo "⚠️ Failed to upload logs to CloudWatch"
        echo "🔍 Debug: Checking log file size: $(wc -l < "$log_file") lines"
        echo "🔍 Debug: Checking JSON file size: $(wc -c < "$temp_json") bytes"
        rm -f "$temp_json"
        return 1
    fi
}

# Function to shutdown EC2 instance
shutdown_ec2_instance() {
    local delay_seconds="${1:-30}"
    
    echo "🛑 Initiating EC2 instance shutdown in ${delay_seconds} seconds..."
    
    # Get instance ID using IMDSv2 (AWS now requires this)
    local instance_id
    local token
    
    # Get IMDSv2 token first
    token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        --connect-timeout 5 --max-time 10 2>/dev/null)
    
    if [ -n "$token" ]; then
        # Use token to get instance ID
        instance_id=$(curl -s -H "X-aws-ec2-metadata-token: $token" \
            http://169.254.169.254/latest/meta-data/instance-id \
            --connect-timeout 5 --max-time 10 2>/dev/null)
    else
        # Fallback to IMDSv1 (may not work on newer instances)
        instance_id=$(curl -s --connect-timeout 5 --max-time 10 \
            http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
    fi
    
    # Validate instance ID format (should be i-xxxxxxxxx, not HTML)
    if [[ ! "$instance_id" =~ ^i-[a-f0-9]+$ ]]; then
        echo "⚠️ Invalid instance ID from metadata, trying AWS CLI..."
        
        # Try to get instance ID from AWS CLI
        instance_id=$(aws ec2 describe-instances \
            --filters "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null)
        
        # Validate the AWS CLI result
        if [[ ! "$instance_id" =~ ^i-[a-f0-9]+$ ]]; then
            echo "⚠️ AWS CLI also failed, using hardcoded value"
            instance_id="i-05b2706eb5c40af2d"  # Hardcoded based on your instance
        else
            echo "✅ Instance ID retrieved via AWS CLI: $instance_id"
        fi
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