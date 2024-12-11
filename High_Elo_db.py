import requests
import pandas as pd
import time
import sqlite3
import random
import db_functions


API_KEY = 'RGAPI-03b47d82-711b-4272-ad48-bd7a9a8d6c76'
sleep = 0
games = 0
append = 0
data = []

def replace_data(data):

    #creating frame for data
    df = pd.json_normalize(data[0])

    for i in range(1,len(data)):
        df_temp = pd.json_normalize(data[i])
        df = pd.concat([df, df_temp])

    del df['legendaryItemUsed']

    connection = sqlite3.connect('lol_database.db')

    query = 'SELECT * FROM Match_Data'

    df_old = pd.read_sql_query(query, connection)

    df = pd.concat([df,df_old])
    print(df.shape)

    df.to_sql('Match_Data', connection, if_exists='replace', index=False)

    connection.close()

def append_data(data):

    df = pd.json_normalize(data[0])

    for i in range(1,len(data)):
        df_temp = pd.json_normalize(data[i])
        df = pd.concat([df, df_temp])

    del df['legendaryItemUsed']

    for col in df.columns:
        if 'SWARM' in col:
            df.pop(col)

    connection = sqlite3.connect('lol_database.db')

    df.to_sql('Match_Data', connection, if_exists='append', index=False)

    '''
    cursor = connection.cursor()
    cursor.execute('SELECT * FROM Match_Data')
    rows = cursor.fetchall()
    print(len(rows))
    '''

    connection.close()


#load username database with only diamond and emerald players
connection = sqlite3.connect('lol_database.db')
cursor = connection.cursor()
cursor.execute('SELECT * FROM Usernames WHERE tier IN ?',('DIAMOND'))
rows = cursor.fetchall()
connection.close()


while games < 20000:

    if append >= 1000:
        append_data(data)
        print('memory cleared')
        data = []
        append = 0
    
    
    #select random player
    rand_summ = random.randrange(0, (len(rows)-1))
    puuid = rows[rand_summ][12]

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
            
            #parsing json into 10 players and adding it to data list
            for player in match_data['info']['participants']:

                player['matchId'] = matchId
                player['gameMode'] = match_data['info']['gameMode']

                data.append(player)
            
            #tracking total games added and games added before last append
            games +=1
            append +=1
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

append_data(data)

'''
connection = sqlite3.connect('lol_database.db')
cursor = connection.cursor()
cursor.execute('SELECT * FROM Match_Data')
rows = cursor.fetchall()
print(len(rows))
connection.close()
'''