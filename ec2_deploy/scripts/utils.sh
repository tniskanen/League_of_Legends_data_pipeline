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
    
    # Use prefix search method (this is the one that works) with hardcoded region
    echo "🔍 Checking if log group exists using prefix search (region: us-east-2)..."
    if aws logs describe-log-groups --region us-east-2 --log-group-name-prefix "$log_group" --query "logGroups[?logGroupName=='$log_group'].logGroupName" --output text 2>/dev/null | grep -q "$log_group"; then
        echo "✅ Log group already exists: $log_group"
    else
        echo "📝 Log group not found, attempting to create: $log_group"
        
        # Try to create the log group
        if aws logs create-log-group --region us-east-2 --log-group-name "$log_group" 2>/dev/null; then
            echo "✅ Log group created successfully: $log_group"
        else
            echo "⚠️ Failed to create CloudWatch log group"
            echo "🔍 Debug: Testing CloudWatch permissions with explicit region..."
            
            # Test specific CloudWatch permissions
            echo "🔍 Testing logs:CreateLogGroup permission..."
            aws logs create-log-group --region us-east-2 --log-group-name "/test-permissions-$(date +%s)" 2>&1 | head -1
            
            echo "🔍 Testing logs:DescribeLogGroups permission..."
            aws logs describe-log-groups --region us-east-2 --max-items 1 2>&1 | head -1
            
            echo "🔍 Final check - does log group exist with prefix search?"
            if aws logs describe-log-groups --region us-east-2 --log-group-name-prefix "$log_group" --query "logGroups[?logGroupName=='$log_group'].logGroupName" --output text 2>/dev/null | grep -q "$log_group"; then
                echo "✅ Log group exists (found after creation attempt): $log_group"
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
    if aws logs create-log-stream --region us-east-2 --log-group-name "$log_group" --log-stream-name "$log_stream" 2>/dev/null; then
        echo "✅ Log stream created: $log_stream"
    else
        echo "⚠️ Failed to create CloudWatch log stream"
        echo "🔍 Debug: Testing log stream creation with error output..."
        aws logs create-log-stream --region us-east-2 --log-group-name "$log_group" --log-stream-name "$log_stream" 2>&1 | head -3
        echo "⚠️ Continuing without CloudWatch logging"
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
    
    # Check log file size and line count
    local file_size=$(wc -c < "$log_file")
    local line_count=$(wc -l < "$log_file")
    echo "🔍 Log file stats: $line_count lines, $file_size bytes"
    
    # CloudWatch limits: 1MB per batch, 10,000 events per batch
    # Limit to first 1000 lines to avoid size issues
    local max_lines=1000
    if [ $line_count -gt $max_lines ]; then
        echo "⚠️ Log file has $line_count lines, limiting to first $max_lines lines for CloudWatch"
    fi
    
    # Create a temporary JSON file for log events
    local temp_json="/tmp/log_events_$(date +%s).json"
    
    # Convert log file to CloudWatch format with line limit
    echo "🔍 Converting log file to CloudWatch format (max $max_lines lines)..."
    head -$max_lines "$log_file" | jq -R -s 'split("\n")[:-1] | map(select(length > 0)) | map({timestamp: (now * 1000 | floor), message: .})' > "$temp_json" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo "❌ Failed to convert log file to JSON format"
        echo "🔍 Debug: Checking if jq is available..."
        which jq >/dev/null 2>&1 || echo "❌ jq command not found"
        return 1
    fi
    
    # Check JSON file size
    local json_size=$(wc -c < "$temp_json")
    local json_events=$(jq length "$temp_json" 2>/dev/null || echo "unknown")
    echo "🔍 JSON stats: $json_events events, $json_size bytes"
    
    # CloudWatch has a 1MB limit, so check if we're under that
    if [ $json_size -gt 1048576 ]; then
        echo "⚠️ JSON file too large ($json_size bytes > 1MB), reducing to first 500 lines"
        head -500 "$log_file" | jq -R -s 'split("\n")[:-1] | map(select(length > 0)) | map({timestamp: (now * 1000 | floor), message: .})' > "$temp_json" 2>/dev/null
        json_size=$(wc -c < "$temp_json")
        echo "🔍 Reduced JSON size: $json_size bytes"
    fi
    
    # Upload to CloudWatch with explicit region and error handling
    echo "🔍 Uploading to CloudWatch (region: us-east-2)..."
    if aws logs put-log-events \
        --region us-east-2 \
        --log-group-name "$log_group" \
        --log-stream-name "$log_stream" \
        --log-events file://"$temp_json" 2>/dev/null; then
        echo "✅ Logs uploaded to CloudWatch successfully"
        rm -f "$temp_json"
        return 0
    else
        echo "⚠️ Failed to upload logs to CloudWatch"
        echo "🔍 Debug: Testing upload with error output..."
        aws logs put-log-events \
            --region us-east-2 \
            --log-group-name "$log_group" \
            --log-stream-name "$log_stream" \
            --log-events file://"$temp_json" 2>&1 | head -5
        
        echo "🔍 Debug: Checking JSON file format..."
        echo "First few characters: $(head -c 100 "$temp_json")"
        echo "Last few characters: $(tail -c 100 "$temp_json")"
        
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