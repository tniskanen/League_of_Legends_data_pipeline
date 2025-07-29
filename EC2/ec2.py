import time
import logging
from Utils.api import highElo, LowElo, matchList, match, handle_api_response
from Utils.S3 import send_json, get_api_key_from_ssm
import psutil
import os

# Configure logging properly
logging.basicConfig(level=logging.INFO, filename='api_errors.log')

start_time = time.time()
start_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

API_KEY = get_api_key_from_ssm("API_KEY")

player_limit = int(os.environ.get("PLAYER_LIMIT", 100000))
bucket = os.environ.get("BUCKET_NAME", 'lol-match-jsons')

# Check if API key was retrieved successfully
if not API_KEY:
    logging.error("Failed to retrieve API key from SSM")
    exit(1)

epochDay = 86400 * 2
low_elo_players = []
high_elo_players = []
matchesList = []
ranks = ['master', 'grandmaster', 'challenger']  
divisions = ['I', 'II', 'III', 'IV']
tiers = ['DIAMOND']
epochTime = int(time.time() - epochDay)

try:
    for rank in ranks:
        json_response = highElo(rank, API_KEY)  # Renamed from 'json' (reserved keyword)
        if json_response and 'entries' in json_response:
            high_elo_players.extend(json_response['entries'])
            if (len(low_elo_players) + len(high_elo_players)) >= player_limit:
                break
        else:
            logging.warning(f"No entries found for rank: {rank}")
except Exception as e:
    logging.error(f"Error during highElo request: {e}. KeyErrors indicate incorrect dictionary returned from API. TypeErrors indicate request exceptions.")

try:
    if (len(low_elo_players) + len(high_elo_players)) < player_limit:
        for tier in tiers:
            for division in divisions:
                page = 1
                while True:
                    json_response = LowElo(tier, division, page, API_KEY)
                    if json_response:
                        low_elo_players.extend(json_response)
                        page+=1
                    else:
                        break

except Exception as e:
    logging.error(f"Error during LowElo request: {e}. KeyErrors indicate incorrect dictionary returned from API. TypeErrors indicate request exceptions.")

# Build a dictionary mapping puuid -> rank data
normalized_high_elo = []

for player in high_elo_players:
    normalized_high_elo.append({
        'puuid': player['puuid'],
        'tier': None, 
        'rank': None, 
        'lp': player.get('leaguePoints', 0)
    })

normalized_low_elo = []

for player in low_elo_players:
    normalized_low_elo.append({
        'puuid': player['puuid'],
        'tier': player['tier'].upper(),  # e.g., "DIAMOND", "PLATINUM"
        'rank': player.get('rank', None),  # e.g., "I", "II", "III", "IV"
        'lp': player.get('leaguePoints', 0)
    })

ranked_players = normalized_high_elo + normalized_low_elo

player_rank_map = {
    player['puuid']: {
        'tier': player['tier'],
        'rank': player['rank'],
        'lp': player['lp']
    }
    for player in ranked_players if 'puuid' in player
}

try:
    for player in ranked_players:
        puuid = player.get('puuid')
        if not puuid:
            continue
        tempMatches = matchList(player['puuid'], API_KEY, epochTime)
        if isinstance(tempMatches, list):
            matchesList.extend(tempMatches)
        else:
            handle_api_response(tempMatches, func_name='matchList', player_id=player['puuid'])
except Exception as e:
    logging.error(f"Error during matchList request: {e}")

uniqueMatches = set(matchesList)
print(f"Found {len(uniqueMatches)} unique matches to process")

upload = 0
total = 0
matches = []
active_threads = []

try:
    for match_id in uniqueMatches:
        temp_data = match(match_id, API_KEY)
        if handle_api_response(temp_data, func_name='match') is None:
            continue
            
        for participant in match['info']['participants']:
            puuid = participant.get('puuid')

            rank_info = player_rank_map.get(puuid)
            if rank_info:
                participant['tier'] = rank_info['tier']
                participant['rank'] = rank_info['rank']
                participant['lp'] = rank_info['lp']
            else:
                participant['tier'] = 'UNKNOWN'
                participant['rank'] = None
                participant['lp'] = None

        matches.append(temp_data)
        upload += 1
        total += 1
        
        if upload >= 500:
            thread = send_json(matches.copy(), bucket)  # Explicit copy
            if thread:
                active_threads.append(thread)
            upload = 0
            matches = []
            print(f"Total matches processed: {total}")
except Exception as e:
    logging.error(f"Error during match processing: {e}")

# Upload remaining matches
if matches:
    thread = send_json(matches, bucket)
    if thread:
        active_threads.append(thread)

# Wait for all uploads
print(f"Waiting for {len(active_threads)} upload threads to complete...")
for thread in active_threads:
    thread.join()

print("All uploads completed!")

end_time = time.time()
end_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

print(f"Runtime: {end_time - start_time:.2f} seconds")
print(f"Memory usage: {start_memory:.1f}MB -> {end_memory:.1f}MB")
print(f"Total matches processed: {total}")