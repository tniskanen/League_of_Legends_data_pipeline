import json
from collections import deque
import mysql.connector
import pandas

def lambda_handler(event, context):
    # TODO implement

    flattened_data = []

    for game in event:
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

    conn = mysql.connector.connect(
    )
    cursor = conn.cursor()

    # Dynamically add new columns if needed
    add_new_columns(cursor, 'your_table', flattened_data)

    # Insert the data into the table
    insert_data_to_mysql(cursor, 'your_table', flattened_data)

    conn.commit()
    cursor.close()
    conn.close()

    return {
        'statusCode': 200,
        'body': json.dumps('Hello from Lambda!')
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
