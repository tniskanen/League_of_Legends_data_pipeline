import pandas as pd
import sqlite3
import db_functions

API_KEY = 'RGAPI-474afa18-b76d-4208-aec9-be9782a51198'
players_list = []
count = 0

ranked = db_functions.masters(API_KEY)
#player list in entries dictionary
players = ranked['entries']

try:
    for player in players:
        count = count+1
        print(count)
        #adding puuid   
        summonerId = player['summonerId']
        puuid = db_functions.puuid(summonerId, API_KEY)
        player['puuid'] = puuid
        player['tier'] = ranked['tier']
        players_list.append(player)

#keyError catches response errors with the ['summonerId'] 
except KeyError:
    print('keyError')
    print(players['status']['status_code'])
    print(players['status']['message'])
    

players_df = pd.DataFrame(players_list)
print(players_df.shape)


connection = sqlite3.connect('lol_database.db')

players_df.to_sql('High_elo_Usernames', connection, if_exists='append', index=False)

cursor = connection.cursor()
cursor.execute('SELECT * FROM High_elo_Usernames')
rows = cursor.fetchall()
print(len(rows))
connection.close()

#make lists of data and create a convert function to make the data into a table
