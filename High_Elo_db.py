import pandas as pd
import sqlite3
import random
import db_functions
import json
import threading
import time


API_KEY = 'RGAPI-99a4aa29-682c-4887-bf3f-042d7013b1e2'
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

'''
connection = sqlite3.connect('lol_database.db')
cursor = connection.cursor()
cursor.execute('SELECT * FROM Match_Data')
rows = cursor.fetchall()
print(len(rows))
connection.close()
'''