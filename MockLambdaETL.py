import json
import pandas as pd
from pandas import json_normalize

def lambda_handler(event, context):
    # TODO implement

    statPerks = json_normalize(event[0]['info']['participants'][0]['perks']['statPerks'], sep='_')
    
    styles = json_normalize(event[0]['info']['participants'][0]['perks']['styles'], 
                            record_path=['selections'],
                            meta=['description','style'],  # Include the 'style' information as meta
                            sep='_'
                            )
    
    player_info = {
    "player_id": '36',
    "name": 'john doe'
    }

    # Flattened statperks into the base player info
    flat_data = {**player_info, **statPerks.to_dict(orient='records')[0]}

    final_data = []
    for idx, row in styles.iterrows():
        flat_data.update(row.to_dict())
        final_data.append(flat_data.copy())

    df = pd.DataFrame(final_data)
    df.to_csv('perksTest.csv',index=False)

    

    '''
    playerList = []
    playerData = event[0]['info']['participants']
    for player in playerData:
        playerList.append(json_normalize(player))

    playerDF = pd.DataFrame(playerList)
    playerDF.to_csv('player.csv', index=False)

    gameData = event[0]
    del gameData['info']['participants']
    gameDF = json_normalize(gameData)
    gameDF.to_csv('game.csv', index=False)
    '''

    return {
        'statusCode': 200,
        'body': json.dumps('Hello from Lambda!')
    }

def flatten_json():
    return

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