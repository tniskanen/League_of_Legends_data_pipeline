import time 
import logging
from Utils.api import highElo, matchList, match, handle_api_response
from Utils.S3 import send_json

#environment variables
import os
from dotenv import load_dotenv
load_dotenv(dotenv_path=r"C:\dev\lol_data_project\variables.env")
API_KEY = os.environ.get("API_KEY")

epochDay = 86400
players = []
matchesList = []
ranks =  ['master','grandmaster','challenger']
epochTime = int(time.time() - epochDay)

try:
    for rank in ranks:
        json = highElo(rank,API_KEY)
        players.extend(json['entries'])

except Exception as e:
    logging.error(f"Error during highElo request: {e}. KeyErrors indicate incorrect dictionary returned from API. TypeErrors indicate request exceptions.")

try:
    for player in players:
        tempMatches = matchList(player['puuid'], API_KEY, epochTime)
        if isinstance(tempMatches,list): 
            matchesList.extend(tempMatches)
        else:
            handle_api_response(tempMatches, func_name='matchList', player_id=player['puuid'])
            
except Exception as e:
    logging.error(f"Error during matchList request: {e}")

uniqueMatches = set(matchesList)

upload = 0
total = 0
matches = []

try:
    for id in uniqueMatches:
        temp_data = match(id, API_KEY)
        if handle_api_response(temp_data, func_name='match') is None:
            continue
            
        matches.append(temp_data)
        upload += 1
        total += 1
        if upload >= 100: 
            send_json(matches) 
            upload = 0
            matches = []
            print(f"Total matches processed: {total}")

except Exception as e:
    logging.error(f"Error during match processing: {e}")

thread = send_json(matches)

thread.join()