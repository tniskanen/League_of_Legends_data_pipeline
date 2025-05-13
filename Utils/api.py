import requests
import logging 
import time

logging.basicConfig(level=logging.INFO, filename='api_errors.log')

def highElo(rank, key, retries=3):
    summoners = None

    #recursion limit
    if retries <= 0:
        logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
        return(summoners)
    
    try:
        url = ('https://na1.api.riotgames.com/lol/league/v4/'+ rank +'leagues/by-queue/' + 
                                'RANKED_SOLO_5x5?api_key=' + key)
        response = requests.get(url)
        summoners = response.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        time.sleep(120)
        return(highElo(key,retries-1))

    #check for response errors
    try:

        #rate limit and server errors
        if summoners['status']['status_code'] >= 429:
            time.sleep(120)
            return(highElo(key,retries-1))
        
        #client errors
        if summoners['status']['status_code'] <= 415:
            logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
            return(summoners)

    #keyError because working with dictionaries
    except KeyError:
        return(summoners)
    
def matchList(puuid, key, epochTime, retries=3):
    matchIds = None

    #recursive limit
    if retries <= 0:
        logging.error(f"Error {matchIds['status']['status_code']}: {matchIds['status']['message']} From url: {url}")
        return matchIds
    
    #requesting match Id for 1 game
    try:
        url = ('https://americas.api.riotgames.com/lol/match/v5/matches/by-puuid/'
                            +puuid+'/ids?startTime='+str(epochTime)+'&queue=420&type=ranked&start=0&count=100&api_key='+key)
        response = requests.get(url)
        matchIds = response.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        time.sleep(120)
        return(matchList(puuid,key,retries-1))

    #check for response errors
    try:
        #server errors/limit rate error
        if matchIds['status']['status_code'] >= 429:
            time.sleep(120)
            return(matchList(puuid,key,retries-1))
        
        #client errors
        if matchIds['status']['status_code'] <= 415:
            logging.error(f"Error {matchIds['status']['status_code']}: {matchIds['status']['message']} From url: {url}")
            return(matchIds)
        
    #type error because working with lists
    except TypeError:
            return(matchIds) 
    
def match(id,key,retries=3):
    match_data = None

    #recursive limit
    if retries <= 0:
        logging.error(f"Error {match_data['status']['status_code']}: {match_data['status']['message']} From url: {url}")
        return(match_data)

    try:
    #request match data
        url = ('https://americas.api.riotgames.com/lol/match/v5/matches/'+
                id +'?api_key=' + key)
        response = requests.get(url)
        match_data = response.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        time.sleep(120)
        return(match(id,key,retries-1))

    #check for response errors
    try:
        #server and rate limit errors
        if match_data['status']['status_code'] >= 429:
            time.sleep(120)
            return(match(id,key,retries-1))

        #client errors
        if match_data['status']['status_code'] <= 415:
            logging.error(f"Error {match_data['status']['status_code']}: {match_data['status']['message']} From url: {url}")
            return(match_data)

    #keyError because working with dictionaries
    except KeyError:
        return(match_data)
    
def champion_mastery(puuid, championid, key, retries=3):

    #recursive limit
    if retries <= 0:
        error_info = {
            "championLevel": "Error" + str(mastery['status']['status_code']),
            "championPoints": "Error" + str(mastery['status']['status_code'])
        }
        logging.error(f"Error {mastery['status']['status_code']}: {mastery['status']['message']} From url: {url}")
        print("server error from champion mastery request")
        return error_info
    
    try:
        url = ('https://na1.api.riotgames.com/lol/champion-mastery/v4/champion-masteries/by-puuid/' + puuid +
                '/by-champion/' + str(championid) +'?api_key=' + key)
        reponse = requests.get(url)
        mastery = reponse.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)

    #check for response errors
    try:
        #check for rate limit and server errors (500-504)
        if mastery['status']['status_code'] >= 429:
            time.sleep(120)
            print("retrying mastery request")
            return(champion_mastery(puuid,championid,key,retries-1))

        #check for client errors or unsupported media errors
        if mastery['status']['status_code'] <= 415:
            error_info = {
                'championLevel': "Error" + str(mastery['status']['status_code']),
                'championPoints': "Error" + str(mastery['status']['status_code'])
            }
            print("client error from mastery request")
            logging.error(f"Error {mastery['status']['status_code']}: {mastery['status']['message']} From url: {url}")
            return error_info
    
    #keyError because 'status' wont be in dictionary
    except KeyError:
        return mastery

def summoner_level(puuid, key, retries=3):

    #recursive limit
    if retries <= 0:
        error_info = {
            "summonerLevel": "Error" + str(summoner_info['status']['status_code']),
            "revisionDate": "Error" + str(summoner_info['status']['status_code'])
        }
        logging.error(f"Error {summoner_info['status']['status_code']}: {summoner_info['status']['message']} From url: {url}")
        print("server error from summoner info request")
        return error_info
        
    try:
        url = ('https://na1.api.riotgames.com/lol/summoner/v4/summoners/by-puuid/' + puuid + '?api_key=' + key)
        reponse = requests.get(url)
        summoner_info = reponse.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)

    #check for response errors
    try:
        #check for rate limit errors or 500-504 server errors
        if summoner_info['status']['status_code'] >= 429:
            time.sleep(120)
            print("retrying summoner information request")
            return(summoner_level(puuid,key, retries-1))
        
        #check for client errors, or unathorized requests
        if summoner_info['status']['status_code'] <= 415:
            error_info = {
            "summonerLevel": "Error" + str(summoner_info['status']['status_code']),
            "revisionDate": "Error" + str(summoner_info['status']['status_code'])
            }
            logging.error(f"Error {summoner_info['status']['status_code']}: {summoner_info['status']['message']} From url: {url}")
            print("client error from summoner info request")
            return error_info

    #keyError because 'status' wont be in dictionary
    except KeyError:
        return summoner_info
    
def handle_api_response(response, func_name, player_id=None):
    if 'status' in response:
        logging.error(f"Error from {func_name} function: {response['status']['status_code']} for player {player_id}")
        return None
    if response is None:
        logging.warning(f"Request error in {func_name} function for player {player_id}")
        return None
    return response   