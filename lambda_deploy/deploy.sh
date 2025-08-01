#!/bin/bash

# Enhanced script to deploy Docker images to AWS Lambda
# Exit on any error
set -e

# Enable command tracing for verbose output if DEBUG is set
if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

echo "🚀 Starting Lambda function deployment..."

# Load environment variables from lambda.env (safer method)
load_env_file() {
  local env_file="$1"
  if [ -f "$env_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      # Skip empty lines and comments
      if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      # Remove leading/trailing whitespace and export
      line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        export "$line"
      fi
    done < "$env_file"
    return 0
  fi
  return 1
}

# FIXED: Actually load the environment file
ENV_FILE="${ENV_FILE:-lambda.env}"
if ! load_env_file "$ENV_FILE"; then
  echo "❌ Error: Environment file '$ENV_FILE' not found. Please create it with required variables."
  exit 1
fi

echo "✅ Loaded environment variables from $ENV_FILE"

# Get AWS Account ID from AWS CLI
echo "🔍 Getting AWS Account ID from AWS CLI..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$AWS_ACCOUNT_ID" ]; then
  echo "❌ Error: Could not get AWS Account ID from AWS CLI. Please check your credentials."
  exit 1
fi
echo "✅ AWS Account ID: $AWS_ACCOUNT_ID"

# Set default values for variables that might come from environment or GitHub
REGION="${REGION:-us-east-1}"
REPO_NAME_LAMBDA="${REPO_NAME_LAMBDA:-lambda-docker-image}"
LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-lol_ETL}"

# Ensure required variables are present (these should come from GitHub secrets/vars)
REQUIRED_VARS=(REGION REPO_NAME_LAMBDA LAMBDA_FUNCTION_NAME LAMBDA_ROLE_ARN)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "❌ Error: $var is not set. This should be provided by GitHub Actions or environment."
    exit 1
  fi
done

# Construct ECR URI
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME_LAMBDA:latest"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
  echo "❌ AWS CLI is not installed. Please install it first."
  exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
  echo "❌ AWS credentials not configured or invalid. Please configure AWS CLI."
  exit 1
fi

# Check if Lambda function exists
echo "🔍 Checking if Lambda function exists..."
if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" --region "$REGION" &> /dev/null; then
  echo "🔄 Lambda function exists. Updating function code..."
  
  # Update existing function code
  aws lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --image-uri "$ECR_URI" \
    --region "$REGION"
  
  echo "⏳ Waiting for function update to complete..."
  aws lambda wait function-updated \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --region "$REGION"
  
  # Update function configuration if environment variables are provided
  if [ -n "${LAMBDA_ENV_VARS}" ]; then
    echo "🔧 Updating Lambda environment variables..."
    aws lambda update-function-configuration \
      --function-name "$LAMBDA_FUNCTION_NAME" \
      --environment "Variables={${LAMBDA_ENV_VARS}}" \
      --region "$REGION"
  fi
  
  # Update timeout if specified
  if [ -n "${LAMBDA_TIMEOUT}" ]; then
    echo "⏱️ Updating Lambda timeout to ${LAMBDA_TIMEOUT} seconds..."
    aws lambda update-function-configuration \
      --function-name "$LAMBDA_FUNCTION_NAME" \
      --timeout "$LAMBDA_TIMEOUT" \
      --region "$REGION"
  fi
  
  # Update memory if specified
  if [ -n "${LAMBDA_MEMORY}" ]; then
    echo "🧠 Updating Lambda memory to ${LAMBDA_MEMORY} MB..."
    aws lambda update-function-configuration \
      --function-name "$LAMBDA_FUNCTION_NAME" \
      --memory-size "$LAMBDA_MEMORY" \
      --region "$REGION"
  fi
  
else
  echo "🔨 Lambda function doesn't exist. Creating new function..."
  
  # Build create-function command
  create_cmd="aws lambda create-function \
    --function-name \"$LAMBDA_FUNCTION_NAME\" \
    --role \"$LAMBDA_ROLE_ARN\" \
    --code ImageUri=\"$ECR_URI\" \
    --package-type Image \
    --region \"$REGION\""
  
  # Add optional parameters if provided
  if [ -n "${LAMBDA_TIMEOUT}" ]; then
    create_cmd="$create_cmd --timeout $LAMBDA_TIMEOUT"
  fi
  
  if [ -n "${LAMBDA_MEMORY}" ]; then
    create_cmd="$create_cmd --memory-size $LAMBDA_MEMORY"
  fi
  
  if [ -n "${LAMBDA_ENV_VARS}" ]; then
    create_cmd="$create_cmd --environment \"Variables={${LAMBDA_ENV_VARS}}\""
  fi
  
  if [ -n "${LAMBDA_DESCRIPTION}" ]; then
    create_cmd="$create_cmd --description \"$LAMBDA_DESCRIPTION\""
  fi
  
  # Execute create command
  eval $create_cmd
  
  echo "⏳ Waiting for function creation to complete..."
  aws lambda wait function-active \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --region "$REGION"
fi

# Test the Lambda function if TEST_PAYLOAD is provided
if [ -n "${TEST_PAYLOAD}" ]; then
  echo "🧪 Testing Lambda function with provided payload..."
  
  # Create temporary file for test payload
  test_payload_file=$(mktemp)
  echo "$TEST_PAYLOAD" > "$test_payload_file"
  
  # Invoke function and capture response
  response_file=$(mktemp)
  if aws lambda invoke \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --payload "file://$test_payload_file" \
    --region "$REGION" \
    "$response_file"; then
    
    echo "✅ Lambda function test successful!"
    echo "📋 Response:"
    cat "$response_file"
    echo
  else
    echo "❌ Lambda function test failed"
  fi
  
  # Clean up temporary files
  rm -f "$test_payload_file" "$response_file"
fi

# Get function information
echo "📊 Lambda function information:"
aws lambda get-function \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --region "$REGION" \
  --query '{
    FunctionName: Configuration.FunctionName,
    Runtime: Configuration.Runtime,
    Handler: Configuration.Handler,
    CodeSize: Configuration.CodeSize,
    Memory: Configuration.MemorySize,
    Timeout: Configuration.Timeout,
    LastModified: Configuration.LastModified,
    State: Configuration.State,
    ImageUri: Code.ImageUri
  }' \
  --output table

# Optionally publish a version
if [ "${PUBLISH_VERSION:-false}" = "true" ]; then
  echo "📦 Publishing new version..."
  version_output=$(aws lambda publish-version \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --region "$REGION" \
    --query 'Version' \
    --output text)
  
  echo "✅ Published version: $version_output"
  
  # Update alias if specified
  if [ -n "${LAMBDA_ALIAS}" ]; then
    echo "🔗 Updating alias: $LAMBDA_ALIAS"
    
    # Check if alias exists
    if aws lambda get-alias \
      --function-name "$LAMBDA_FUNCTION_NAME" \
      --name "$LAMBDA_ALIAS" \
      --region "$REGION" &> /dev/null; then
      
      # Update existing alias
      aws lambda update-alias \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --name "$LAMBDA_ALIAS" \
        --function-version "$version_output" \
        --region "$REGION"
    else
      # Create new alias
      aws lambda create-alias \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --name "$LAMBDA_ALIAS" \
        --function-version "$version_output" \
        --region "$REGION"
    fi
    
    echo "✅ Alias $LAMBDA_ALIAS updated to version $version_output"
  fi
fi

echo "✅ Lambda deployment complete!"
echo "🔗 Function ARN: arn:aws:lambda:$REGION:$AWS_ACCOUNT_ID:function:$LAMBDA_FUNCTION_NAME"