import requests
import pandas as pd
import time
import sqlite3
import random

#choose a sample randomly given a weighted distribution
def weighted_random_sample():

    categories = [['IRON','IV'], ['IRON','III'], ['IRON','II'], ['IRON','I'],
                  ['BRONZE','IV'], ['BRONZE','III'], ['BRONZE','II'], ['BRONZE','I'],
                  ['SILVER','IV'], ['SILVER','III'], ['SILVER','II'], ['SILVER','I'],
                  ['GOLD','IV'],['GOLD','III'], ['GOLD','II'], ['GOLD','I'],
                  ['PLATINUM','IV'], ['PLATINUM','III'], ['PLATINUM','II'], ['PLATINUM','I'],
                  ['EMERALD','IV'], ['EMERALD','III'], ['EMERALD','II'], ['EMERALD','I'],
                  ['DIAMOND','IV'], ['DIAMOND','III'], ['DIAMOND','II'], ['DIAMOND','I'],
                  ['MASTER','I'], ['GRANDMASTER','I'], ['CHALLENGER','I']]
    weights = [0.044,0.039,0.035,0.028,
               0.065,0.053,0.052,0.04,
               0.083,0.057,0.049,0.033,
               0.077,0.046,0.037,0.024,
               0.054,0.029,0.022,0.014,
               0.03917,0.02217,0.01617,0.01417,
               0.012,0.0049,0.0035,0.0028,
               0.0034,0.00051,0.00021]
    
    total_weight = sum(weights)
    normalized_weights = [weight / total_weight for weight in weights]

    #return 1 rank based off of weighted distribution
    return random.choices(categories,weights=normalized_weights,k=1)

def rank_and_id(key):
    #get a random rank
    rank = weighted_random_sample()

    #check if rank it above diamond because those ranks have differnt api requests
    if rank[0][0] == 'CHALLENGER':
        summoners = challenger(key)
        puuid = random_select_player(summoners['entries'],key)
        rank.append(puuid)

    if rank[0][0] == 'GRANDMASTER':
        summoners = grandmasters(key)
        puuid = random_select_player(summoners['entries'],key)
        rank.append(puuid)

    if rank[0][0] == 'MASTER':
        summoners = masters(key)
        puuid = random_select_player(summoners['entries'],key)
        rank.append(puuid)

    #diamond and below
    else:
        summoners = tier_division(tier=rank[0][0], division=rank[0][1], key=key)
        puuid = random_select_player(summoners,key)
        rank.append(puuid)

    return rank


## API REQUESTS FOR LIST OF SUMMONERS BY LEAGUES 
def grandmasters(key):
    while True:
        response = requests.get('https://na1.api.riotgames.com/lol/league/v4/grandmasterleagues/by-queue/' + 
                                'RANKED_SOLO_5x5?api_key=' + key)
        summoners = response.json()
        try:

            #fix rate limit error
            if summoners['status']['status_code'] == 429:
                time.sleep(120)

            #other error that cant be handled with this function
            else:
                break

        #keyError because working with dictionaries
        except KeyError:
            break
    
    return(summoners)

def masters(key):
    while True:
        response = requests.get('https://na1.api.riotgames.com/lol/league/v4/masterleagues/by-queue/' + 
                                'RANKED_SOLO_5x5?api_key='+key)
        summoners = response.json()
        try:

            #fix rate limit error
            if summoners['status']['status_code'] == 429:
                time.sleep(120)

            #other error that cant be handled with this function
            else:
                break

        #keyError because working with dictionaries
        except KeyError:
            break

    return(summoners)

def challenger(key):
    while True:
        response = requests.get('https://na1.api.riotgames.com/lol/league/v4/challengerleagues/by-queue/' + 
                                'RANKED_SOLO_5x5?api_key='+key)
        summoners = response.json()
        try:

            #fix rate limit error
            if summoners['status']['status_code'] == 429:
                time.sleep(120)

            #other error that cant be handled with this function
            else:
                break

        #keyError because working with dictionaries
        except KeyError:
            break

    return(summoners)

def tier_division(tier,division,key):
    while True:
        #getting correct number of pages for each rank. Ranks like silver and gold will have much larger amount of usernames,
        #so a lower page number will result in much higher likelihood of repeated samples
        match tier:
            case 'DIAMOND':
                page = random.randrange(1,17)
            case 'EMERALD':
                page = random.randrange(1,60)
            case 'PLATINUM':
                page = random.randrange(1,60)
            case 'GOLD':
                page = random.randrange(1,134)
            case 'SILVER':
                page = random.randrange(1,179)
            case 'BRONZE':
                page = random.randrange(1,227)
            case 'IRON':
                page = random.randrange(1,167)

        response = requests.get('https://na1.api.riotgames.com/lol/league/v4/entries/RANKED_SOLO_5x5/'+ tier + '/' +
                                division + '?page='+ str(page) +'&api_key='+ key)
        summoners = response.json()
        try:

            #check for empty list of summoners
            if not summoners:
                continue

            #fix rate limit error
            if summoners['status']['status_code'] == 429:
                time.sleep(120)

            #other error that cant be handled with this function
            else:
                break

        #keyError because working with dictionaries
        except TypeError:
            break

    return(summoners)

## FUNCTIONS FOR RANDOMLY SELECTING SUMMONER AND ACQUIRING PUUID
def random_select_player(players,key):
    rand_summ = random.randrange(0, (len(players)-1))
    player = players[rand_summ]
    summonerId = player['summonerId']
    puuid = get_puuid(summonerId, key)

    return puuid

def get_puuid(summoner_id, key):
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
