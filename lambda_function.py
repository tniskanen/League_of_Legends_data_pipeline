import json
from collections import deque
import mysql.connector
import boto3
from dotenv import load_dotenv
import os

def lambda_handler(event, context):

    #loading environment variables
    load_dotenv()
    DB_HOST = os.environ.get("DB_HOST")
    DB_NAME = os.environ.get("DB_NAME")
    DB_USER = os.environ.get("DB_USER")
    DB_PASSWORD = os.environ.get("DB_PASSWORD")

    s3_client = boto3.client('s3')

    bucket = event['Records'][0]['s3']['bucket']['name']
    fileKey = event['Records'][0]['s3']['object']['key']

    try:
        s3_object = s3_client.get_object(Bucket=bucket, Key=fileKey)
        file_content = s3_object['Body'].read()
        data = json.loads(file_content.decode('utf-8'))

        flattened_data = []

        for game in data:
            for player in game['info']['participants']:
                temp_player = flatten_json(player)

                temp_player['tier'] = game['tier']
                temp_player['division'] = game['division']

                temp_player['dataVersion'] = game['metadata']['dataVersion']
                temp_player['matchId'] = game['metadata']['matchId']

                temp_player['gameCreation'] = game['info']['gameCreation']
                temp_player['gameDuration'] = game['info']['gameDuration']
                temp_player['gameVersion'] = game['info']['gameVersion']
                temp_player['mapId'] = game['info']['mapId']

                flattened_data.append(temp_player)
        
        columns = {}
        
        for json_obj in flattened_data:
            for key, value in json_obj.items():
                # Dynamically determine the column type
                if isinstance(value, int):
                    column_type = "INT"
                elif isinstance(value, float):
                    column_type = "FLOAT"
                elif isinstance(value, str):
                    column_type = "VARCHAR(255)"
                elif isinstance(value, bool):  # Check for booleans
                    column_type = "TINYINT(1)"  # MySQL convention for boolean
                else:
                    column_type = "TEXT"  # For unsupported types
                
                # Only update the column type if it hasn't been seen before (for consistency)
                if key not in columns:
                    columns[key] = column_type

        column_defs = [f"`{col}` {col_type}" for col, col_type in columns.items()]
        create_table_query = f"""
        CREATE TABLE IF NOT EXISTS RankedData (
            {', '.join(column_defs)})
        """ 

        insert_query = f"INSERT INTO RankedData ({', '.join(columns.keys())}) VALUES ({', '.join(['%s'] * len(columns))})"

        insert_data = []
        for json_obj in flattened_data:
                # Make sure the values match the order of the columns in the INSERT query
                row_data = tuple(json_obj.get(col, None) for col in columns.keys())
                insert_data.append(row_data)

        conn = mysql.connector.connect(
            host=DB_HOST,
            user=DB_USER,
            password=DB_PASSWORD,
            database=DB_NAME
        )
        cursor = conn.cursor()

        cursor.execute(create_table_query)
        conn.commit()
        
        cursor.executemany(insert_query, insert_data)
        conn.commit()

        cursor.close()
        conn.close()

        return {
            'statusCode': 200,
            'body': json.dumps('Hello from Lambda!')
        }

    except mysql.connector.Error as err:
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error: {err}")
        }
        
    except Exception as e:
        return {
            'statusCode': 500,
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

def get_existing_columns(cursor, table_name):
    cursor.execute(f"DESCRIBE {table_name}")
    return [column[0] for column in cursor.fetchall()]

def add_new_columns(cursor, table_name, json_data):
    existing_columns = get_existing_columns(cursor, table_name)
    new_columns = [key for key in json_data.keys() if key not in existing_columns]
    
    for column in new_columns:
        cursor.execute(f"ALTER TABLE {table_name} ADD COLUMN {column} VARCHAR(255)")
        print(f"Added new column: {column}")

def insert_data_to_mysql(cursor, table_name, data):
    # Prepare the INSERT statement with placeholders
    columns = ', '.join(data.keys())
    placeholders = ', '.join(['%s'] * len(data))
    sql = f"INSERT INTO {table_name} ({columns}) VALUES ({placeholders})"
    # Execute the INSERT
    cursor.execute(sql, list(data.values()))
