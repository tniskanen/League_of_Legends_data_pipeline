import json
from collections import deque
import boto3
import os
import logging
import mysql.connector


# Setting up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)
# This ensures logs are directed to CloudWatch
handler = logging.StreamHandler()
logger.addHandler(handler)

from dotenv import load_dotenv

def lambda_handler(bucket, fileKey):
    
    #loading environment variables locally
    load_dotenv(dotenv_path=r"C:\dev\lol_data_project\variables.env")

    DB_HOST = os.getenv("DB_HOST")
    DB_NAME = os.environ.get("DB_NAME")
    DB_USER = os.environ.get("DB_USER")
    DB_PASSWORD = os.environ.get("DB_PASSWORD")

    s3_client = boto3.client('s3')

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
                insert_data_to_mysql(cursor, table, batch_data)  
                conn.commit()



    except mysql.connector.Error as err:
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error: {err}")
        }
        
    except Exception as e:
        return {
            'statusCode': 501,
            'body': json.dumps(f"Error: {str(e)}")
        }
    
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
    
    finally:
        # Ensuring resources are closed
        try:
            cursor.close()
            conn.close()
        except NameError:  # In case the connection is never created
            logger.error("Database connection or cursor not initialized.")

    return {
            'statusCode': 200,
            'body': json.dumps('data uploaded!')
        }


def flatten_json(nested_json):

    """Flatten the JSON into a single level (row)."""
    out = {}  # This will hold the flattened result
    queue = deque([((), nested_json)])  # Initialize a queue with the root of the JSON structure

    while queue:  # Loop through the queue until it's empty
        path, current = queue.popleft()  # Get the current path and data from the queue

        # If the current element is a dictionary:
        if isinstance(current, dict):
            for key, value in current.items():
                new_path = path + (key,)  # Create a new path by appending the current key
                queue.append((new_path, value))  # Add the new path and value to the queue

        # If the current element is a list:
        elif isinstance(current, list):
            for idx, item in enumerate(current):  # Iterate through each item in the list
                new_path = path + (str(idx),)  # Create a new path by appending the index
                queue.append((new_path, item))  # Add the new path and item to the queue

        # If the current element is a value (neither dict nor list):
        else:
            out["_".join(path)] = current  # Join the path into a string (using underscores) and store the value

    return out  # Return the flattened dictionary

#helper function
def get_existing_columns(cursor, table_name):
    cursor.execute(f"DESCRIBE {table_name}")
    return [column[0] for column in cursor.fetchall()]

#helper function
def add_new_columns(cursor, table_name, new_columns):
    existing_columns = get_existing_columns(cursor, table_name)
    for column in new_columns:
        if column not in existing_columns:
            cursor.execute(f"ALTER TABLE {table_name} ADD COLUMN {column} VARCHAR(255)")
            print(f"Added new column: {column}")

def align_row_data(row, existing_columns):
    return [row.get(col, None) for col in existing_columns]

def insert_data_to_mysql(cursor, table_name, rows):
    # Retrieve the current columns in the table (do this only once)
    existing_columns = get_existing_columns(cursor, table_name)

    # Get all unique columns from the rows and identify the missing columns
    new_columns = set(col for row in rows for col in row.keys())
    
    # Add missing columns to the table
    add_new_columns(cursor, table_name, new_columns)
    
    # Align all rows with the existing columns (fill in None for missing columns)
    aligned_rows = [align_row_data(row, existing_columns) for row in rows]
    
    # Prepare the INSERT statement with placeholders for each column
    placeholders = ', '.join(['%s'] * len(existing_columns))
    sql = f"INSERT INTO {table_name} ({', '.join(existing_columns)}) VALUES ({placeholders})"
    
    # Use executemany to insert all rows at once
    cursor.executemany(sql, aligned_rows)
    print(f"Inserted {len(aligned_rows)} rows into {table_name}")

def split_json(flat_dict):
    legendaryItems = {}
    challenges = {}
    perkMissionStats = {}
    basicStats = {}

    for key, value in flat_dict.keys():
        if key.startswith('perks') or key.startswith('missions'):
            perkMissionStats[key] = value
        elif key.startswith('challenges'):
            if key.startswith('challenges_legendaryItemUsed'):
                legendaryItems[key] = value
            else:
                challenges[key] = value
        else:
            basicStats[key] = value

    dicts = [basicStats, challenges, legendaryItems, perkMissionStats]
    return dicts

def add_join_keys(dicts):

    #add keys for joins
    for i in range(1, 4):
        dicts[i]['matchId'] = dicts[0]['matchId']
        dicts[i]['championName'] = dicts[0]['championName']

    return dicts

def s3_files(bucket_name):

    s3_client = boto3.client('s3')
    # List all objects in the S3 bucket
    response = s3_client.list_objects_v2(Bucket=bucket_name)
    return response['Contents']
    '''
    for obj in response['Contents']:
        # Get the file key (filename)
        file_key = obj['Key']

        # Fetch the file from S3 (you can load the file in-memory or download it)
        file = s3_client.get_object(Bucket=bucket_name, Key=file_key)
    '''

if __name__ == "__main__":
    bucket = 'lol-match-jsons'
    keyInfo = s3_files(bucket)
    key = keyInfo[224]['Key']
    
    x = lambda_handler(bucket, key)
    print(x['statusCode'])
    print(x['body'])
    
    