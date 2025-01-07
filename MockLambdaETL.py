import json
import pandas as pd
from pandas import json_normalize
from collections import deque

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

    df = pd.DataFrame(flattened_data)
    df.to_csv('Test.csv',index=False)


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

class MockContext:
    def __init__(self):
        self.function_name = 'my_lambda_function'  # The name of the Lambda function
        self.memory_limit_in_mb = 128  # The amount of memory allocated to the function
        self.aws_request_id = '12345-abcde'  # A mock AWS request ID
        self.log_group_name = '/aws/lambda/my_lambda_function'  # The log group for your Lambda function
        self.log_stream_name = '2024/12/20/[$LATEST]abcde12345'  # The log stream name
        self.invoke_id = 'invoke-id'  # The invocation ID for the request

    def get_remaining_time_in_millis(self):
        return 30000  # The remaining time before Lambda times out (in milliseconds)


if __name__== '__main__':
    context = MockContext()
    with open('data.json', 'r') as file:
    # Parse the JSON file into a Python dictionary (or list, depending on the structure)
        data = json.load(file)

    lambda_handler(data,context)