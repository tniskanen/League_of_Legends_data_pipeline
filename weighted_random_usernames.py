import requests
import pandas as pd
import time
import sqlite3
import random
import logging

logging.basicConfig(level=logging.INFO, filename='api_errors.log')

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

    try:
        #check if rank it above diamond because those ranks have differnt api requests
        if rank[0][0] == 'CHALLENGER':
            summoners = challenger(key)
            summoner = random_select_player(summoners['entries'],key)
            puuid = summoner['puuid']
            rank.append(puuid)

        if rank[0][0] == 'GRANDMASTER':
            summoners = grandmasters(key)
            summoner = random_select_player(summoners['entries'],key)
            puuid = summoner['puuid']
            rank.append(puuid)

        if rank[0][0] == 'MASTER':
            summoners = masters(key)
            summoner = random_select_player(summoners['entries'],key)
            puuid = summoner['puuid']
            rank.append(puuid)

        #diamond and below
        else:
            summoners = tier_division(tier=rank[0][0], division=rank[0][1], key=key)
            summoner = random_select_player(summoners,key)
            puuid = summoner['puuid']
            rank.append(puuid)

        return rank
    
    except KeyError:
        return rank


## API REQUESTS FOR LIST OF SUMMONERS BY LEAGUES 
def grandmasters(key,retries=3):
    
    #recursion limit
    if retries <= 0:
        logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
        return(summoners)
    
    url = ('https://na1.api.riotgames.com/lol/league/v4/grandmasterleagues/by-queue/' + 
                            'RANKED_SOLO_5x5?api_key=' + key)
    response = requests.get(url)
    summoners = response.json()

    #check for response errors
    try:

        #rate limit and server errors
        if summoners['status']['status_code'] >= 429:
            time.sleep(120)
            return(grandmasters(key,retries-1))
        
        #client errors
        if summoners['status']['status_code'] <= 415:
            logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
            return(summoners)

    #keyError because working with dictionaries
    except KeyError:
        return(summoners)

def masters(key,retries=3):
    
    #recursion limit
    if retries <= 0:
        logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
        return(summoners)
    
    url = ('https://na1.api.riotgames.com/lol/league/v4/masterleagues/by-queue/' + 
            'RANKED_SOLO_5x5?api_key='+key)
    response = requests.get(url)
    summoners = response.json()
    try:

        #server or rate limit error
        if summoners['status']['status_code'] >= 429:
            time.sleep(120)
            return(masters(key,retries-1))

        #client error
        if summoners['status']['status_code'] <= 415:
            logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
            return(summoners)

    #keyError because working with dictionaries
    except KeyError:
        return(summoners)


def challenger(key,retries=3):
    
    #recursion limit
    if retries <= 0:
        logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
        return(summoners)
    
    url = ('https://na1.api.riotgames.com/lol/league/v4/challengerleagues/by-queue/' + 
                            'RANKED_SOLO_5x5?api_key='+key)
    response = requests.get(url)
    summoners = response.json()
    try:

        #server error
        if summoners['status']['status_code'] >= 429:
            time.sleep(120)
            return(challenger(key,retries-1))

        #client error
        if summoners['status']['status_code'] <= 415:
            logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
            return(summoners)
        
    #keyError because working with dictionaries
    except KeyError:
        return(summoners)

#more retries incase of empty page
def tier_division(tier,division,key,retries=5):

    #recursion limit
    if retries <= 0:

        #in case recursion because of epmty page
        if not summoners:
            #returning empty dict to catch key error in main function to abort current attempt
            empty_dict = {'NA':0}
            return empty_dict
        else:
            logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
            return(summoners)
    
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

    url = ('https://na1.api.riotgames.com/lol/league/v4/entries/RANKED_SOLO_5x5/'+ tier + '/' +
                            division + '?page='+ str(page) +'&api_key='+ key)
    response = requests.get(url)
    summoners = response.json()
    try:

        #check for empty list of summoners
        if not summoners:
            return(tier_division(tier,division,key,retries-1))

        #server or rate limit error
        if summoners['status']['status_code'] >= 429:
            time.sleep(120)
            return(tier_division(tier,division,key,retries-1))

        # client error
        if summoners['status']['status_code'] <= 415: 
            logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
            return(summoners)

    #TypeError because a list is returned 
    except TypeError:
        return(summoners)

## FUNCTIONS FOR RANDOMLY SELECTING SUMMONER AND ACQUIRING PUUID
def random_select_player(players,key):
    rand_summ = random.randrange(0, (len(players)-1))
    player = players[rand_summ]
    summonerId = player['summonerId']
    puuid = get_puuid(summonerId, key)

    return puuid

def get_puuid(summoner_id, key,retries=3):
    
    #recursive limit
    if retries <= 0:
        logging.error(f"Error {player['status']['status_code']}: {player['status']['message']} From url: {url}")
        return(player)
    
    url = ('https://na1.api.riotgames.com/lol/summoner/v4/summoners/'+
            summoner_id+'?api_key='+key)
    response = requests.get(url)
    player = response.json()

    #catching response errors 
    try:

        #server or rate limit errors
        if player['status']['status_code'] >= 429:
            time.sleep(120)
            return(get_puuid(summoner_id,key,retries-1))

        #client errors
        if player['status']['status_code'] <= 415:
            logging.error(f"Error {player['status']['status_code']}: {player['status']['message']} From url: {url}")
            return(player)

    #keyError because working with dictionaries
    except KeyError:
        return(player)
