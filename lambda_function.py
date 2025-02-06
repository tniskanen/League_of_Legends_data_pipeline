import json
from collections import deque
import boto3
from dotenv import load_dotenv
import os

import mysql.connector

def lambda_handler(bucket, fileKey):
    
    #loading environment variables
    load_dotenv(dotenv_path=r"C:\dev\lol_data_project\variables.env")

    #dont zip this part. only used for locally connecting to database
    DB_HOST = os.getenv("DB_HOST")
    DB_NAME = os.environ.get("DB_NAME")
    DB_USER = os.environ.get("DB_USER")
    DB_PASSWORD = os.environ.get("DB_PASSWORD")

    s3_client = boto3.client('s3')
    #uncomment when deploying
    '''
    bucket = event['Records'][0]['s3']['bucket']['name']
    fileKey = event['Records'][0]['s3']['object']['key']
    '''

    try:

        s3_object = s3_client.get_object(Bucket=bucket, Key=fileKey)
        file_content = s3_object['Body'].read()
        data = json.loads(file_content.decode('utf-8'))

        print('info from s3 bucket received')
        flattened_data = []

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

                flattened_data.append(temp_player)
        

        print('attempting to connect to database')
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
        for i in range(0, len(flattened_data), batch_size):
            batch_data = flattened_data[i:i + batch_size]  # Get the current batch of 200 rows
            insert_data_to_mysql(cursor, "RankedDataPrototype", batch_data)  
            conn.commit()

        cursor.close()
        conn.close()
        print('connection complete!')

        return {
            'statusCode': 200,
            'body': json.dumps('data uploaded!')
        }

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
    
    for i in range(3,len(keyInfo)):
        x = lambda_handler(bucket, keyInfo[i]['Key'])
        print(i)
        print(x['statusCode'])
        print(x['body'])
    
    
    