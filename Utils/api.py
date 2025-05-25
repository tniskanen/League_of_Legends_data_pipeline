import requests
import logging 
import time

logging.basicConfig(level=logging.INFO, filename='api_errors.log')

def highElo(rank, key, retries=3):
    summoners = None
    url = None  # Initialize url variable

    # Recursion limit
    if retries <= 0:
        if summoners and 'status' in summoners:
            logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
        else:
            logging.error(f"Failed to retrieve data for rank {rank} after all retries")
        return summoners
    
    try:
        url = ('https://na1.api.riotgames.com/lol/league/v4/'+ rank +'leagues/by-queue/' + 
                                'RANKED_SOLO_5x5?api_key=' + key)
        response = requests.get(url)
        summoners = response.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        time.sleep(120)
        return highElo(rank, key, retries-1)  # Fixed parameter order

    # Check for response errors
    try:
        # Rate limit and server errors
        if summoners['status']['status_code'] >= 429:
            time.sleep(120)
            return highElo(rank, key, retries-1)  # Fixed parameter order
        
        # Client errors
        if summoners['status']['status_code'] <= 415:
            logging.error(f"Error {summoners['status']['status_code']}: {summoners['status']['message']} From url: {url}")
            return summoners

    # KeyError because working with dictionaries
    except KeyError:
        return summoners
    
def matchList(puuid, key, epochTime, retries=3):
    matchIds = None
    url = None  # Initialize url variable

    # Recursive limit
    if retries <= 0:
        if matchIds and 'status' in matchIds:
            logging.error(f"Error {matchIds['status']['status_code']}: {matchIds['status']['message']} From url: {url}")
        else:
            logging.error(f"Failed to retrieve match list for puuid {puuid} after all retries")
        return matchIds
    
    # Requesting match Id for games
    try:
        url = ('https://americas.api.riotgames.com/lol/match/v5/matches/by-puuid/'
                            +puuid+'/ids?startTime='+str(epochTime)+'&queue=420&type=ranked&start=0&count=100&api_key='+key)
        response = requests.get(url)
        matchIds = response.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        time.sleep(120)
        return matchList(puuid, key, epochTime, retries-1)  # Fixed parameter order

    # Check for response errors
    try:
        # Server errors/limit rate error
        if matchIds['status']['status_code'] >= 429:
            time.sleep(120)
            return matchList(puuid, key, epochTime, retries-1)  # Fixed parameter order
        
        # Client errors
        if matchIds['status']['status_code'] <= 415:
            logging.error(f"Error {matchIds['status']['status_code']}: {matchIds['status']['message']} From url: {url}")
            return matchIds
        
    # TypeError because working with lists (successful response)
    except TypeError:
        return matchIds 
    
def match(id, key, retries=3):
    match_data = None
    url = None  # Initialize url variable

    # Recursive limit
    if retries <= 0:
        if match_data and 'status' in match_data:
            logging.error(f"Error {match_data['status']['status_code']}: {match_data['status']['message']} From url: {url}")
        else:
            logging.error(f"Failed to retrieve match data for id {id} after all retries")
        return match_data

    try:
        # Request match data
        url = ('https://americas.api.riotgames.com/lol/match/v5/matches/'+
                id +'?api_key=' + key)
        response = requests.get(url)
        match_data = response.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        time.sleep(120)
        return match(id, key, retries-1)

    # Check for response errors
    try:
        # Server and rate limit errors
        if match_data['status']['status_code'] >= 429:
            time.sleep(120)
            return match(id, key, retries-1)

        # Client errors
        if match_data['status']['status_code'] <= 415:
            logging.error(f"Error {match_data['status']['status_code']}: {match_data['status']['message']} From url: {url}")
            return match_data

    # KeyError because working with dictionaries (successful response)
    except KeyError:
        return match_data
    
def champion_mastery(puuid, championid, key, retries=3):
    mastery = None
    url = None  # Initialize url variable

    # Recursive limit
    if retries <= 0:
        error_info = {
            "championLevel": "Error",
            "championPoints": "Error"
        }
        if mastery and 'status' in mastery:
            error_info["championLevel"] = f"Error{mastery['status']['status_code']}"
            error_info["championPoints"] = f"Error{mastery['status']['status_code']}"
            logging.error(f"Error {mastery['status']['status_code']}: {mastery['status']['message']} From url: {url}")
        else:
            logging.error(f"Failed to retrieve champion mastery for puuid {puuid} after all retries")
        print("server error from champion mastery request")
        return error_info
    
    try:
        url = ('https://na1.api.riotgames.com/lol/champion-mastery/v4/champion-masteries/by-puuid/' + puuid +
                '/by-champion/' + str(championid) +'?api_key=' + key)
        response = requests.get(url)  # Fixed typo: reponse -> response
        mastery = response.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        time.sleep(120)
        return champion_mastery(puuid, championid, key, retries-1)

    # Check for response errors
    try:
        # Check for rate limit and server errors (500-504)
        if mastery['status']['status_code'] >= 429:
            time.sleep(120)
            print("retrying mastery request")
            return champion_mastery(puuid, championid, key, retries-1)

        # Check for client errors or unsupported media errors
        if mastery['status']['status_code'] <= 415:
            error_info = {
                'championLevel': f"Error{mastery['status']['status_code']}",
                'championPoints': f"Error{mastery['status']['status_code']}"
            }
            print("client error from mastery request")
            logging.error(f"Error {mastery['status']['status_code']}: {mastery['status']['message']} From url: {url}")
            return error_info
    
    # KeyError because 'status' won't be in dictionary (successful response)
    except KeyError:
        return mastery

def summoner_level(puuid, key, retries=3):
    summoner_info = None
    url = None  # Initialize url variable

    # Recursive limit
    if retries <= 0:
        error_info = {
            "summonerLevel": "Error",
            "revisionDate": "Error"
        }
        if summoner_info and 'status' in summoner_info:
            error_info["summonerLevel"] = f"Error{summoner_info['status']['status_code']}"
            error_info["revisionDate"] = f"Error{summoner_info['status']['status_code']}"
            logging.error(f"Error {summoner_info['status']['status_code']}: {summoner_info['status']['message']} From url: {url}")
        else:
            logging.error(f"Failed to retrieve summoner info for puuid {puuid} after all retries")
        print("server error from summoner info request")
        return error_info
        
    try:
        url = ('https://na1.api.riotgames.com/lol/summoner/v4/summoners/by-puuid/' + puuid + '?api_key=' + key)
        response = requests.get(url)  # Fixed typo: reponse -> response
        summoner_info = response.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        time.sleep(120)
        return summoner_level(puuid, key, retries-1)

    # Check for response errors
    try:
        # Check for rate limit errors or 500-504 server errors
        if summoner_info['status']['status_code'] >= 429:
            time.sleep(120)
            print("retrying summoner information request")
            return summoner_level(puuid, key, retries-1)
        
        # Check for client errors, or unauthorized requests
        if summoner_info['status']['status_code'] <= 415:
            error_info = {
                "summonerLevel": f"Error{summoner_info['status']['status_code']}",
                "revisionDate": f"Error{summoner_info['status']['status_code']}"
            }
            logging.error(f"Error {summoner_info['status']['status_code']}: {summoner_info['status']['message']} From url: {url}")
            print("client error from summoner info request")
            return error_info

    # KeyError because 'status' won't be in dictionary (successful response)
    except KeyError:
        return summoner_info
    
def handle_api_response(response, func_name, player_id=None):
    if response is None:
        logging.warning(f"Request error in {func_name} function for player {player_id}")
        return None
    if 'status' in response:
        logging.error(f"Error from {func_name} function: {response['status']['status_code']} for player {player_id}")
        return None
    return response