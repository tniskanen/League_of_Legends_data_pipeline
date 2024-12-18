import pandas as pd
import sqlite3
import random
import db_functions
import json
import threading
import time


API_KEY = 'RGAPI-2c39b6c7-9929-44c8-a475-4403018c10e4'
sleep = 0
games = 0
append = 0
temp_data = []


#load username database with only diamond and emerald players
connection = sqlite3.connect('lol_database.db')
connection.row_factory = sqlite3.Row
cursor = connection.cursor()
cursor.execute('SELECT * FROM High_elo_Usernames WHERE tier = ?',('GRANDMASTER',))
rows = cursor.fetchall()
connection.close()


while games < 100:

    if append >= 1000:
        thread = db_functions.send_json(temp_data)
        print('memory cleared')
        temp_data = []
        append = 0
    
    
    #select random player
    rand_summ = random.randrange(0, (len(rows)-1))
    puuid = rows[rand_summ]['puuid']

    #fetch matchIDS
    matchIds = db_functions.matches(puuid, API_KEY)

    #check for response errors, looping using indexing to catch dictionaries
    #because matchIds should be lists
    try:
        for id in range(len(matchIds)):
            matchId = matchIds[id]
            match_data = db_functions.data(matchId, API_KEY)

            #remove games that never started
            if match_data['info']['gameDuration'] == 0:
                continue
            
            #adding player rank/tier to json
            match_data['tier'] = rows[rand_summ]['tier']
            match_data['rank'] = rows[rand_summ]['rank']

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

        #remove player from randomized list
        del rows[rand_summ]

    #exception for dictionary indexing for MATCH DATA (data request)
    except KeyError:
        print('keyError')
        print(match_data)
        continue

    #exception for list indexing for MATCH IDs (matches request) 
    except ValueError:
        print(matchIds['status']['status_code'])
        print(matchIds['status']['message'])
        #remove player from selection list
        del rows[rand_summ]
        continue

thread = db_functions.send_json(temp_data)

thread.join()
