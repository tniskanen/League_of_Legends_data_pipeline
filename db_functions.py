import requests
import pandas as pd
import time
import sqlite3
import random

def matches(puuid,key):
    while True:

        #requesting match Ids
        url = ('https://americas.api.riotgames.com/lol/match/v5/matches/by-puuid/'
                            +puuid+'/ids?type=ranked&start=0&count=100&api_key='+key)
        response = requests.get(url)
        matchIds = response.json()

        #if rate limit exceeded, sleep and re-try request
        try:
            if matchIds['status']['status_code'] == 429:
                time.sleep(120)
            
            #if a status code exists thats not rate limit return
            else:
                break

        #type error because working with lists
        except TypeError:
            break
        
    return(matchIds)  
        
def data(id,key):
    while True:
        #request match data
        response = requests.get('https://americas.api.riotgames.com/lol/match/v5/matches/'+
                                id +'?api_key=' + key)
        match_data = response.json()

        #if rate limit exceeded, sleep
        try:
            if match_data['status']['status_code'] == 429:
                time.sleep(120)
                
            #if a status code exists thats not rate limit return
            else:
                break

        #keyError because working with dictionaries
        except KeyError:
            break
    return(match_data)


#no rate limit issue because there is only 1 request
def grandmasters(key):
    response = requests.get('https://na1.api.riotgames.com/lol/league/v4/grandmasterleagues/by-queue/' + 
                            'RANKED_SOLO_5x5?api_key=' + key)
    summoners = response.json()
    return(summoners)


#no rate limit issue because there is only 1 request
def masters(key):
    response = requests.get('https://na1.api.riotgames.com/lol/league/v4/masterleagues/by-queue/' + 
                            'RANKED_SOLO_5x5?api_key='+key)
    summoners = response.json()
    return(summoners)


def puuid(summoner_id, key):
    while True:
        response = requests.get('https://na1.api.riotgames.com/lol/summoner/v4/summoners/'+
                                summoner_id+'?api_key='+key)
        player = response.json()

        try:

            #fix rate limit error
            if player['status']['status_code'] == 429:
                time.sleep(120)

            #other error that cant be handled with this function
            else:
                break

        #keyError because working with dictionaries
        except KeyError:
            break
    return(player['puuid']) 
