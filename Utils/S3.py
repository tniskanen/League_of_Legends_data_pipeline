import time
import boto3
import json
import threading
from botocore.exceptions import NoCredentialsError, PartialCredentialsError, ClientError
import logging
import os

logging.basicConfig(level=logging.INFO, filename='api_errors.log')
 
def upload_to_s3(bucket, key, data):
    try:
        #connect to client
        s3 = boto3.client('s3')
        print('client connection good')
        #upload data
        s3.put_object(Bucket=bucket,Key=key,Body=data)
        print(f"successful upload of {key}")
    
    except NoCredentialsError:
        print("NoCredentialsError")
    except PartialCredentialsError:
        print("PartialCredentialsError")
    except ClientError as e:
        print("Error uploading to s3")
    except Exception as e:
        print("unexpected Error occured")
    

def send_json(data):

    #convert data into jsons
    json_data = json.dumps(data)

    bucket = 'lol-match-jsons'
    s3_key = f'match_{int(time.time())}_json_objects.json'

    #start upload on new thread
    upload_thread = threading.Thread(target=upload_to_s3, args=(bucket,s3_key,json_data))
    upload_thread.start()

    print("JSON upload is happening in the background...")
    return upload_thread


def get_api_key_from_ssm(parameter_name: str) -> str:
    """
    Retrieves the API key (or any other parameter) from AWS SSM Parameter Store.
    
    :param parameter_name: The name of the parameter stored in SSM.
    :return: The parameter value if successful, or None if there's an error.
    """
    # Initialize the boto3 SSM client
    ssm_client = boto3.client('ssm')

    try:
        # Fetch the parameter from SSM
        response = ssm_client.get_parameter(
            Name=parameter_name,
            WithDecryption=True  # Decrypt the parameter if it's a secure string
        )
        # Return the parameter value
        return response['Parameter']['Value']
    
    except ssm_client.exceptions.ParameterNotFound:
        print(f"Error: The parameter '{parameter_name}' was not found.")
        return None
    
    except Exception as e:
        print(f"Error retrieving parameter: {str(e)}")
        return None

###SAVING JSON LOCALLY TO TEST LAMBDA ETL
def save_json(data):
    file_path = os.path.join(os.getcwd(), f'match_json_objects_{int(time.time())}.json') 
    with open(file_path, 'w') as json_file:
        json.dump(data,json_file)
    print('complete')