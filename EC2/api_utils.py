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
    
def handle_api_response(response, func_name, player_id=None):
    if 'status' in response:
        logging.error(f"Error from {func_name} function: {response['status']['status_code']} for player {player_id}")
        return None
    if response is None:
        logging.warning(f"Request error in {func_name} function for player {player_id}")
        return None
    return response   