import requests
import pandas as pd
import time 
import sqlite3

API_KEY = ''

division = ['I', 'II', 'III', 'IV']
tierlist = ['IRON','BRONZE','SILVER','GOLD','PLATINUM','EMERALD','DIAMOND']
queue = 'RANKED_SOLO_5x5'

players_list = []
sleep = 0
pages = 30

for page in range(22,pages):
    page = page + 1
    print(page)
    for tier in tierlist:
        for div in division:

            if sleep == 99:
                print('sleeping at pit stop 1')
                time.sleep(120)
                sleep = 0
                
            url = ('https://na1.api.riotgames.com/lol/league/v4/entries/'
                    +queue+'/'+tier+'/'+div+'?page='+str(page)+'&api_key='+API_KEY)
            response = requests.get(url)
            players  = response.json()
            sleep = sleep + 1

            for player in players:

                if sleep == 99:
                    print('sleeping at pit stop 2')
                    time.sleep(120)
                    sleep = 0
                
                #adding puuid   
                summonerId = player['summonerId']
                url = ('https://na1.api.riotgames.com/lol/summoner/v4/summoners/'
                       +summonerId+'?api_key='+API_KEY)
                response = requests.get(url)
                summ= response.json()
                sleep = sleep + 1
                player['puuid'] = summ['puuid']

                if sleep == 99:
                    print('sleeping at pit stop 3')
                    time.sleep(120)
                    sleep = 0
                
                #adding matchIds
                '''
                puuid = player['puuid']
                url = ('https://americas.api.riotgames.com/lol/match/v5/matches/by-puuid/'
                       +puuid+'/ids?start=0&count=100&api_key='+API_KEY)
                response = requests.get(url)
                matchIds = response.json()
                sleep = sleep + 1
                player['matchIds'] = matchIds
                '''
                players_list.append(player)

players_df = pd.DataFrame(players_list)
print(players_df.shape)

'''
connection = sqlite3.connect('lol_database.db')
players_df.to_sql('Usernames', connection, 
                  if_exists='replace',index=False)

cursor = connection.cursor()
cursor.execute('SELECT * FROM Usernames')
rows = cursor.fetchall()

print(len(rows))

connection.close()
'''

## NEED TO CHANGE PAGES!!!!!

connection = sqlite3.connect('lol_database.db')

new_rows = players_df
new_rows.to_sql('Usernames', connection, if_exists='append', index=False)

cursor = connection.cursor()
cursor.execute('SELECT * FROM Usernames')
rows = cursor.fetchall()
print(len(rows))
connection.close()

#make lists of data and create a convert function to make the data into a table
