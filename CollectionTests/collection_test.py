from dotenv import load_dotenv
import os
import mysql.connector
import json
import requests
import time 
import logging 
import sql_utils

logging.basicConfig(level=logging.INFO, filename='api_errors.log')
load_dotenv(dotenv_path=r"C:\dev\lol_data_project\variables.env")

DB_HOST = os.getenv("DB_HOST")
DB_NAME = os.environ.get("DB_NAME")
DB_USER = os.environ.get("DB_USER")
DB_PASSWORD = os.environ.get("DB_PASSWORD")

API_KEY = os.environ.get("API_KEY")

count_file = "collection_count.json"

def get_game_count():
    if os.path.exists(count_file):
        with open(count_file, "r") as file:
            data = json.load(file)
            return data.get("COLLECTION_COUNT", 0)
    return 0

# Function to update the request count in the JSON file
def update_request_count(count):
    with open(count_file, "w") as file:
        json.dump({"COLLECTION_COUNT": count}, file)

def data(id,key,retries=3):
    match_data = None
    #recursive limit
    if retries <= 0:
        logging.error(f"Error {match_data['status']['status_code']}: {match_data['status']['message']} From url: {url}")
        return(match_data)

    try:
    #request match data
        url = ('https://americas.api.riotgames.com/lol/match/v5/matches/'+
                id +'?api_key=' + key)
        response = requests.get(url)
        match_data = response.json()

    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        return None

    #check for response errors
    try:
        #server and rate limit errors
        if match_data['status']['status_code'] >= 429:
            time.sleep(120)
            return(data(id,key,retries-1))
        else:
            return(match_data)

    #keyError because working with dictionaries ([status])
    except KeyError:
        return(match_data)
    
def upload_to_mysql(data, db_config):
    try:
        # Create a connection to the MySQL database
        connection = mysql.connector.connect(**db_config)
        cursor = connection.cursor()

        sql_utils.insert_data_to_mysql(cursor, 'collectionTest', data)
        connection.commit()
    except mysql.connector.Error as err:
        logging.error(f"MySQL Error: {err}", exc_info=True)
    finally:
        cursor.close()
        connection.close()

def main():
    game_number = get_game_count()
    prefix = "NA1_"
    matches = []
    db_config = {
        'host':DB_HOST,
        'user':DB_USER,
        'password':DB_PASSWORD,
        'database':DB_NAME
    }
    
    try:
        for _ in range(70000):
            gameID = prefix + str(game_number)
            print(gameID)

            temp_data = {
            }

            #request from api
            match_data = data(gameID, API_KEY)

            if match_data is not None:
                try:
                    status = match_data.get('status',None)
                    #try to retain client error codes
                    if status is not None:
                        temp_data['queueId'] = match_data['status']['status_code']
                        temp_data['endGameResult'] = match_data['status']['message']
                        temp_data['gameId'] = game_number
                        #call a function to fill in null values
                    elif match_data['httpStatus'] <= 415:
                        temp_data['queueId'] = match_data['httpStatus']
                        temp_data['endGameResult'] = match_data['errorCode']
                        temp_data['gameId'] = game_number

                except KeyError:
                    temp_data.update(match_data.pop('info'))
                    del temp_data['participants']
                    del temp_data['teams']
            else:
                continue
            matches.append(temp_data)
            game_number += 1

    except Exception as e:
        print(f"An error occurred: {e}")

    finally:
        update_request_count(game_number)
        batch_size = 1000
        for i in range(0, len(matches), batch_size):
            batch = matches[i:i + batch_size]  # Slice the list to get the batch
            upload_to_mysql(batch, db_config)  # Upload the current batch
        

            

if __name__ == "__main__":
    main()
    print('complete!')