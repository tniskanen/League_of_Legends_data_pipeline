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

###SAVING JSON LOCALLY TO TEST LAMBDA ETL
def save_json(data):
    file_path = os.path.join(os.getcwd(), f'match_json_objects_{int(time.time())}.json') 
    with open(file_path, 'w') as json_file:
        json.dump(data,json_file)
    print('complete')