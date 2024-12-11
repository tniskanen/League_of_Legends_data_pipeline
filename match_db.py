import requests
import pandas as pd
import time
import sqlite3
import random


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


#load username database 
connection = sqlite3.connect('lol_database.db')
cursor = connection.cursor()
cursor.execute('SELECT * FROM Usernames')
rows = cursor.fetchall()
connection.close()


while games < 20000:

    if append >= 1000:
        append_data(data)
        print('memory cleared')
        data = []
        append = 0
    
    #get matchIds
    rand_summ = random.randrange(0, (len(rows)-1))
    puuid = rows[rand_summ][12]
    url = ('https://americas.api.riotgames.com/lol/match/v5/matches/by-puuid/'
                        +puuid+'/ids?start=0&count=100&api_key='+API_KEY)
    response = requests.get(url)
    matchIds = response.json()
    sleep += 1

    if sleep == 99:
        print('sleeping')
        time.sleep(120)
        sleep = 0

    #select random match
    try:
        rand_match = random.randrange(0, (len(matchIds) - 1))
        matchId = matchIds[rand_match]
        
        
    except ValueError:
        print('valueError')
        print(matchIds)
        continue

    #request game data
    response = requests.get('https://americas.api.riotgames.com/lol/match/v5/matches/'
                                    + matchId +'?api_key=' + API_KEY)
    match_data = response.json()
    sleep +=1

    if sleep == 99:
        print('sleeping')
        time.sleep(120)
        sleep = 0

    try:
        
        while match_data['info']['gameMode'] != 'CLASSIC' or match_data['info']['gameDuration'] == 0:
            print('not classic')

            matchIds.remove(matchId)
            if len(matchIds) == 2:
                break

            rand_match = random.randrange(0, (len(matchIds) - 1))
            matchId = matchIds[rand_match]

            response = requests.get('https://americas.api.riotgames.com/lol/match/v5/matches/'
                                        + matchId +'?api_key=' + API_KEY)
            match_data = response.json()
            sleep += 1 

            if sleep == 99:
                print('sleeping')
                time.sleep(120)
                sleep = 0
        
        if len(matchIds) == 2:
            print('hardstuck summoner')
            continue

    except KeyError:
        print('keyError')
        print(match_data)
        continue

    for player in match_data['info']['participants']:

        player['matchId'] = matchId
        player['gameMode'] = match_data['info']['gameMode']

        #removing challenges
        try:
            for challenge in player['challenges']:
                player[challenge] = player['challenges'][challenge]
            del player['challenges']

        except KeyError:
            print('no challenges')

        #removing perks
        del player['perks']
        
        data.append(player)

    games +=1
    append +=1
    print(games)

append_data(data)

'''
connection = sqlite3.connect('lol_database.db')
cursor = connection.cursor()
cursor.execute('SELECT * FROM Match_Data')
rows = cursor.fetchall()
print(len(rows))
connection.close()
'''