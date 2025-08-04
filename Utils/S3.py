import time
import boto3
import json
import threading
from botocore.exceptions import NoCredentialsError, PartialCredentialsError, ClientError
import logging
from datetime import datetime, timezone
import os

# Enable debugging for boto3 credentials if DEBUG_AWS_CREDS environment variable is set
if os.environ.get("DEBUG_AWS_CREDS", "false").lower() == "true":
    boto3.set_stream_logger('botocore.credentials', logging.DEBUG)
    print("AWS credential debugging enabled")

# Configure logging
logging.basicConfig(level=logging.INFO, filename='api_errors.log')

def test_aws_credentials():
    """Test if AWS credentials are properly configured and accessible."""
    try:
        
        
        # Try to get caller identity (lightweight call)
        region = os.environ.get('AWS_REGION', 'us-east-2')
        sts_client = boto3.client('sts', region_name=region)
        identity = sts_client.get_caller_identity()
        print(f"AWS credentials working - authenticated as: {identity['Arn']}")
        
        # Output environment variables for debugging
        print("AWS Environment Variables:")
        aws_vars = ['AWS_REGION', 'AWS_EC2_METADATA_DISABLED', 'AWS_EC2_METADATA_SERVICE_ENDPOINT', 
                    'AWS_EC2_METADATA_TOKEN', 'AWS_SDK_LOAD_CONFIG']
        for var in aws_vars:
            print(f"  {var}: {os.environ.get(var, 'Not set')}")
            
        return True
    except Exception as e:
        print(f"AWS credential test failed: {str(e)}")
        return False

def upload_to_s3(bucket, key, data):
    """Enhanced upload function with better logging"""
    try:
        data = json.dumps(data)
        region = os.environ.get('AWS_REGION', 'us-east-2')
        s3 = boto3.client('s3', region_name=region)
        
        s3.put_object(Bucket=bucket, Key=key, Body=data)
        print(f"✓ Successfully uploaded: {key}")
        
    except Exception as e:
        print(f"✗ Upload failed: {key} - Error: {str(e)}")
        import traceback
        traceback.print_exc()
        raise

def send_json(data, bucket, custom_date=None, source=None):
    """
    Upload JSON to S3 with date-based folder structure
    
    Args:
        data: The match data to upload
        bucket: S3 bucket name
        custom_date: Optional datetime object, defaults to current UTC time
        source: Optional source string, if 'test' it will be added to the beginning of the S3 key
    """
    if not data:
        return None
        
    # Create a deep copy to avoid shared state
    data_copy = json.loads(json.dumps(data))
    
    # Get date for folder structure
    if custom_date:
        upload_date = custom_date
    else:
        upload_date = datetime.now(timezone.utc)
    
    # Create date-based folder structure
    year = upload_date.strftime('%Y')
    month = upload_date.strftime('%m')
    day = upload_date.strftime('%d')
    hour = upload_date.strftime('%H')
    
    # Create hierarchical key structure
    timestamp = int(time.time() * 1000)
    match_count = len(data_copy)

    s3_key_hive = f"matches/year={year}/month={month}/day={day}/batch_{timestamp}_{match_count}_matches.json"
    
    # Apply source prefix if source is 'test'
    if source == 'test':
        s3_key = f"{source}/{s3_key_hive}"
    else:
        s3_key = s3_key_hive

    # Enhance the JSON with metadata
    enhanced_data = {
        'metadata': {
            'upload_timestamp': upload_date.isoformat(),
            'match_count': match_count,
            'batch_id': f"{year}{month}{day}_{timestamp}",
            's3_key': s3_key
        },
        'matches': data_copy
    }
    
    # Start upload on new thread (upload_to_s3 will handle json.dumps)
    upload_thread = threading.Thread(
        target=upload_to_s3, 
        args=(bucket, s3_key, enhanced_data)
    )
    upload_thread.start()

    print(f"Queued upload: {match_count} matches -> {s3_key}")
    return upload_thread

def get_parameter_from_ssm(parameter_name):
    """
    Retrieves a parameter from AWS SSM Parameter Store.
    
    :param parameter_name: The name of the parameter stored in SSM.
    :return: The parameter value if successful, or None if there's an error.
    """
    # Initialize the boto3 SSM client with enhanced configuration
    region = os.environ.get("AWS_REGION", "us-east-2")
    
    try:
        # Create SSM client with explicit configuration
        ssm_client = boto3.client('ssm', region_name=region)
        
        # Fetch the parameter from SSM
        response = ssm_client.get_parameter(
            Name=parameter_name,
            WithDecryption=True
        )
        return response['Parameter']['Value']
    
    except Exception as e:
        print(f"Error retrieving parameter: {str(e)}")
        return None

def pull_s3_object(bucket, filepath):
    """
    Download and return JSON data from S3 object
    
    Args:
        bucket: S3 bucket name
        filepath: S3 object key/path
        
    Returns:
        dict: Parsed JSON data from S3 object, or None if error
    """
    try:
        region = os.environ.get('AWS_REGION', 'us-east-2')
        s3 = boto3.client('s3', region_name=region)
        
        response = s3.get_object(Bucket=bucket, Key=filepath)
        file_content = response['Body'].read().decode('utf-8')
        data = json.loads(file_content)
        
        print(f"✓ Successfully downloaded: {filepath}")
        return data
        
    except Exception as e:
        print(f"✗ Error downloading {filepath}: {str(e)}")
        return None

def alter_s3_file(bucket, key, operation, data=None):
    """
    Modify or delete an S3 object
    
    Args:
        bucket: S3 bucket name
        key: S3 object key/path
        operation: Either "overwrite" or "delete"
        data: Required for "overwrite" operation, ignored for "delete"
        
    Returns:
        bool: True if successful, False if error
    """
    try:
        region = os.environ.get('AWS_REGION', 'us-east-2')
        s3 = boto3.client('s3', region_name=region)
        
        if operation == "overwrite":
            if data is None:
                print(f"✗ Error: data is required for overwrite operation")
                return False
            
            # Convert data to JSON if it's not already a string
            if not isinstance(data, str):
                data = json.dumps(data)
            
            s3.put_object(Bucket=bucket, Key=key, Body=data)
            print(f"✓ Successfully overwritten: {key}")
            return True
            
        elif operation == "delete":
            s3.delete_object(Bucket=bucket, Key=key)
            print(f"✓ Successfully deleted: {key}")
            return True
            
        else:
            print(f"✗ Error: Invalid operation '{operation}'. Must be 'overwrite' or 'delete'")
            return False
            
    except Exception as e:
        print(f"✗ Error during {operation} operation on {key}: {str(e)}")
        return False

###SAVING JSON LOCALLY TO TEST LAMBDA ETL
def save_json(data):
    file_path = os.path.join(os.getcwd(), f'match_json_objects_{int(time.time())}.json') 
    with open(file_path, 'w') as json_file:
        json.dump(data, json_file)
    print('complete')

# Test AWS credentials when this module is imported
test_aws_credentials()