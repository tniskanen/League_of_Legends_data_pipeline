import pandas as pd
import random
import db_functions
import weighted_random_usernames
import json
import threading
import time


API_KEY = 'RGAPI-965e7112-946d-4c9e-9d3e-d1a3d53f4432'
games = 0
append = 0
temp_data = []


while games < 20000:

    if append >= 1000:
        thread = db_functions.send_json(temp_data)
        print('memory cleared')
        temp_data = []
        append = 0
    
    
    #select random player
    rank_and_Id = weighted_random_usernames.rank_and_id(API_KEY)
    puuid = rank_and_Id[1]

    #fetch matchIDS
    matchId = db_functions.matches(puuid, API_KEY)

    #check for response errors, looping using indexing to catch dictionaries
    #because matchIds should be lists
    try:
        
        match_data = db_functions.data(matchId[0], API_KEY)

        #remove games that never started
        if match_data['info']['gameDuration'] == 0:
            continue
        
        #adding player rank/tier to json
        match_data['tier'] = rank_and_Id[0][0]
        match_data['division'] = rank_and_Id[0][1]

        #adding summoner level and champion mastery to each participant 
        for player in match_data['info']['participants']:

            #temporary IDs for summoner and mastery requests
            temp_puuid = player['puuid']
            temp_champ_ID = player['championId']

            #summoner level and last time the summoner level was revised 
            summoner_info = db_functions.summoner_level(temp_puuid, API_KEY)
            player['summonerLevel'] = summoner_info['summonerLevel']
            player['summonerLevelRevisionDate'] = summoner_info['revisionDate']

            #add champion mastery by level and points
            mastery = db_functions.champion_mastery(temp_puuid,temp_champ_ID,API_KEY)
            player['masteryLevel'] = mastery['championLevel']
            player['masteryPoints'] = mastery['championPoints']
        
        temp_data.append(match_data)

        #tracking total games added and games added before last append
        games +=1
        append +=1
        print(games)


    #exception for dictionary indexing for MATCH DATA (data request)
    except KeyError:
        print('keyError')
        print(match_data)
        continue

    #exception for list indexing for MATCH IDs (matches request) 
    except ValueError:
        print(matchId['status']['status_code'])
        print(matchId['status']['message'])
        continue

thread = db_functions.send_json(temp_data)

thread.join()
