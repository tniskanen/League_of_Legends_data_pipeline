import pandas as pd
import db_functions
import weighted_random_usernames
import logging
from dotenv import load_dotenv
import os

logging.basicConfig(level=logging.INFO, filename='api_errors.log')

#loading environment variable
load_dotenv(dotenv_path=r"C:\dev\lol_data_project\variables.env")
API_KEY = os.environ.get('API_KEY')

games = 0
append = 0
temp_data = []


while games <= 100:

    if append >= 1000:
        thread = db_functions.send_json(temp_data)
        print('memory cleared')
        temp_data = []
        append = 0

    #check for response errors, looping using indexing to catch dictionaries
    #because matchIds should be lists
    try:
        #select random player
        rank_and_Id = weighted_random_usernames.rank_and_id(API_KEY)
        puuid = rank_and_Id[1]

        #fetch matchID
        matchId = db_functions.matches(puuid, API_KEY)
        
        match_data = db_functions.data(matchId[0], API_KEY)

        #remove games that never started
        if match_data['info']['gameDuration'] == 0:
            continue
        
        #adding player rank/tier to json
        match_data['tier'] = rank_and_Id[0][0]
        match_data['division'] = rank_and_Id[0][1]

        temp_data.append(match_data)

        #tracking total games added and games added before last append
        games +=1
        append +=1
        print(games)

    #exception for rank_and_id where puuid wasnt appended to rank
    #error will be caught initializing puuid variable
    except IndexError:
        continue

    #exception for incorrect key when parsing match_data from data() function
    except KeyError:
        print('keyError')
        continue

    #unsure why i added this  
    except ValueError:
        print(matchId['status']['status_code'])
        print(matchId['status']['message'])
        continue

    #exception for providing key to list matchId from matches() function 
    except TypeError:
        print('TypeError')
        continue

thread = db_functions.send_json(temp_data)

thread.join()
