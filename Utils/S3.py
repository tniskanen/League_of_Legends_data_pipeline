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

def upload_to_s3(bucket, key, data, match_count):
    """Enhanced upload function with better logging"""
    try:
        region = os.environ.get('AWS_REGION', 'us-east-2')
        s3 = boto3.client('s3', region_name=region)
        
        s3.put_object(Bucket=bucket, Key=key, Body=data)
        print(f"✓ Successfully uploaded: {key} ({match_count} matches)")
        
    except Exception as e:
        print(f"✗ Upload failed: {key} - Error: {str(e)}")
        import traceback
        traceback.print_exc()
        raise

def send_json(data, bucket, custom_date=None):
    """
    Upload JSON to S3 with date-based folder structure
    
    Args:
        data: The match data to upload
        custom_date: Optional datetime object, defaults to current UTC time
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
    
    json_data = json.dumps(enhanced_data)

    # Start upload on new thread
    upload_thread = threading.Thread(
        target=upload_to_s3, 
        args=(bucket, s3_key, json_data, match_count)
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

def list_matches_by_date(bucket, year, month=None, day=None):
    """
    List all match files for a specific date range
    
    Args:
        bucket: S3 bucket name
        year: Year (e.g., '2025')
        month: Optional month (e.g., '05')
        day: Optional day (e.g., '25')
    """
    s3 = boto3.client('s3')
    
    # Build prefix based on provided parameters
    if day and month:
        prefix = f"matches/year={year}/month={month}/day={day}/"
    elif month:
        prefix = f"matches/year={year}/month={month}/"
    else:
        prefix = f"matches/year={year}/"
    
    try:
        response = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
        
        if 'Contents' in response:
            files = [obj['Key'] for obj in response['Contents']]
            print(f"Found {len(files)} files in {prefix}")
            return files
        else:
            print(f"No files found in {prefix}")
            return []
            
    except Exception as e:
        print(f"Error listing files: {str(e)}")
        return []

def get_match_data_for_date(bucket, year, month, day):
    """
    Download and combine all match data for a specific date
    """
    files = list_matches_by_date(bucket, year, month, day)
    all_matches = []
    
    s3 = boto3.client('s3')
    
    for file_key in files:
        try:
            response = s3.get_object(Bucket=bucket, Key=file_key)
            file_content = response['Body'].read().decode('utf-8')
            data = json.loads(file_content)
            
            # Handle both old and new formats
            if 'matches' in data:
                all_matches.extend(data['matches'])
            else:
                # Old format - assume it's directly a list of matches
                if isinstance(data, list):
                    all_matches.extend(data)
                else:
                    all_matches.append(data)
                    
        except Exception as e:
            print(f"Error reading {file_key}: {str(e)}")
    
    print(f"Retrieved {len(all_matches)} total matches for {year}-{month}-{day}")
    return all_matches

###SAVING JSON LOCALLY TO TEST LAMBDA ETL
def save_json(data):
    file_path = os.path.join(os.getcwd(), f'match_json_objects_{int(time.time())}.json') 
    with open(file_path, 'w') as json_file:
        json.dump(data, json_file)
    print('complete')

# Test AWS credentials when this module is imported
test_aws_credentials()