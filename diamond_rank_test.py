from Utils.api import highElo, LowElo, matchList, handle_api_response
import logging
import time

API_KEY = 'RGAPI-eb1ffdf7-a854-4baa-b95a-d3d85324e9d4'
ranks = ['master', 'grandmaster', 'challenger']
divisions = ['I', 'II']
tiers = ['DIAMOND']

players =[]
matchesList = []
epochDay = 86400
epochTime = int(time.time() - epochDay)

start_time = time.time()

try:
    for rank in ranks:
        json_response = highElo(rank, API_KEY)  # Renamed from 'json' (reserved keyword)
        if json_response and 'entries' in json_response:
            players.extend(json_response['entries'])
        else:
            logging.warning(f"No entries found for rank: {rank}")
except Exception as e:
    logging.error(f"Error during highElo request: {e}. KeyErrors indicate incorrect dictionary returned from API. TypeErrors indicate request exceptions.")

highEloLength = len(players)
print(f"Retrieved {len(players)} players from high elo ranks")

try:
    for tier in tiers:
        for division in divisions:
            page = 1
            while True:
                json_response = LowElo(tier, division, page, API_KEY)
                if json_response:
                    players.extend(json_response)
                    page+=1
                else:
                    break

except Exception as e:
    logging.error(f"Error during LowElo request: {e}. KeyErrors indicate incorrect dictionary returned from API. TypeErrors indicate request exceptions.")

print(f"Retrieved {len(players) - highEloLength} players from low elo ranks")

print(f"Total players collected: {len(players)}")

try:
    for player in players:
        tempMatches = matchList(player['puuid'], API_KEY, epochTime)
        if isinstance(tempMatches, list):
            matchesList.extend(tempMatches)
        else:
            handle_api_response(tempMatches, func_name='matchList', player_id=player['puuid'])
except Exception as e:
    logging.error(f"Error during matchList request: {e}")

uniqueMatches = set(matchesList)
print(f"Found {len(uniqueMatches)} unique matches to process")

end_time = time.time()
print(f"⏱️ Script runtime: {end_time - start_time:.2f} seconds")