import json
import boto3
import os
import logging
import mysql.connector
import Utils.sql as sql
from Utils.json import flatten_json, split_json, add_join_keys
from Utils.S3 import get_api_key_from_ssm


# Setting up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)
# This ensures logs are directed to CloudWatch
handler = logging.StreamHandler()
logger.addHandler(handler)


def lambda_handler(bucket, fileKey):
    
    #loading environment variables
    DB_HOST = get_api_key_from_ssm("DB_HOST-dev")
    DB_NAME = get_api_key_from_ssm("DB_NAME-dev")
    DB_USER = get_api_key_from_ssm("DB_USER")
    DB_PASSWORD = get_api_key_from_ssm("DB_PASSWORD-dev")

    s3_client = boto3.client('s3')
    
    # Initialize these variables so they exist for the finally block
    cursor = None
    conn = None

    try:
        #uncomment when deploying
        '''
        bucket = event['Records'][0]['s3']['bucket']['name']
        fileKey = event['Records'][0]['s3']['object']['key']
        '''

        s3_object = s3_client.get_object(Bucket=bucket, Key=fileKey)
        file_content = s3_object['Body'].read()
        data = json.loads(file_content.decode('utf-8'))

        tables = {
            'BasicStats': [],
            'challengeStats': [],
            'legendaryItem': [],
            'perkMissionStats': []
        }
        
        for game in data:
            logger.info(f"Processing game: {game.get('metadata', {}).get('matchId', 'Unknown')}")
            
            for player in game['info']['participants']:

                temp_player = flatten_json(player)

                temp_player['tier'] = game['tier']
                ## division was renamed from rank at some point during data collection
                temp_player['division'] = game.get('rank') or game.get('division')

                temp_player['dataVersion'] = game['metadata']['dataVersion']
                temp_player['matchId'] = game['metadata']['matchId']

                temp_player['gameCreation'] = game['info']['gameCreation']
                temp_player['gameDuration'] = game['info']['gameDuration']
                temp_player['gameVersion'] = game['info']['gameVersion']
                temp_player['mapId'] = game['info']['mapId']
                
                #sorting data for seperate tables, create join keys, add temp dictionaries to data lists
                dicts = add_join_keys(split_json(temp_player))
                tables['BasicStats'].append(dicts[0])
                tables['challengeStats'].append(dicts[1])
                tables['legendaryItem'].append(dicts[2])
                tables['perkMissionStats'].append(dicts[3])
        
        print(len(tables['BasicStats']))
        logger.info(f"Total BasicStats records: {len(tables['BasicStats'])}")
        
        conn = mysql.connector.connect(
            host=DB_HOST,
            user=DB_USER,
            password=DB_PASSWORD,
            database=DB_NAME
        )

        cursor = conn.cursor()

        # Define the batch size
        batch_size = 200
    
        # Process data in batches
        for table in tables:
            temp_table = tables[table]
            for i in range(0, len(temp_table), batch_size):

                batch_data = temp_table[i:i + batch_size]  # Get the current batch of 200 rows
                sql.insert_data_to_mysql(cursor, table, batch_data)  
                conn.commit()
        
    except s3_client.exceptions.NoSuchBucket as e:
        logger.error(f"s3 NoSuchBucket Error: {e}")
        return {
            'statusCode': 404,
            'body': json.dumps(f"S3 Bucket Error: {str(e)}")
        }
    
    except s3_client.exceptions.NoSuchKey as e:
        logger.error(f"s3 NoSuchKey Error: {e}")
        return {
            'statusCode': 404,
            'body': json.dumps(f"S3 File Error: {str(e)}")
        }
        
    except mysql.connector.Error as err:
        logger.error(f"MySQL Error: {err}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Database Error: {err}")
        }
        
    except KeyError as e:
        logger.error(f"KeyError - Missing expected key in data: {e}")
        return {
            'statusCode': 400,
            'body': json.dumps(f"Data structure error - missing key: {str(e)}")
        }
        
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return {
            'statusCode': 501,
            'body': json.dumps(f"Unexpected Error: {str(e)}")
        }
    
    finally:
        # Ensuring resources are closed
        if cursor:
            cursor.close()
        if conn:
            conn.close()

    return {
            'statusCode': 200,
            'body': json.dumps('data uploaded!')
        }

def s3_files(bucket_name):

    s3_client = boto3.client('s3')
    # List all objects in the S3 bucket
    response = s3_client.list_objects_v2(Bucket=bucket_name)
    return response['Contents']
    

if __name__ == "__main__":
    bucket = 'lol-match-jsons'
    keyInfo = s3_files(bucket)
    key = keyInfo[0]['Key']
    
    lambda_handler(bucket, key)