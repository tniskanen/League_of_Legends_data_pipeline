import time
import logging
from Utils.api import highElo, matchList, match, handle_api_response
from Utils.S3 import send_json, get_api_key_from_ssm
import psutil

# Configure logging properly
logging.basicConfig(level=logging.INFO, filename='api_errors.log')

start_time = time.time()
start_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

API_KEY = get_api_key_from_ssm("API_KEY")

# Check if API key was retrieved successfully
if not API_KEY:
    logging.error("Failed to retrieve API key from SSM")
    exit(1)

epochDay = 86400
players = []
matchesList = []
ranks = ['master', 'grandmaster', 'challenger']  # Fixed missing quotes
epochTime = int(time.time() - epochDay)

try:
    for rank in ranks:
        json_response = highElo(rank, API_KEY)  # Renamed from 'json' (reserved keyword)
        if json_response and 'entries' in json_response:
            players.extend(json_response['entries'])
        else:
            logging.warning(f"No entries found for rank: {rank}")
except Exception as e:
    logging.error(f"Error during highElo request: {e}. KeyErrors indicate incorrect dictionary returned from API. TypeErrors indicate request exceptions.")

print(f"Retrieved {len(players)} players from high elo ranks")

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

upload = 0
total = 0
matches = []
active_threads = []

try:
    for match_id in uniqueMatches:
        temp_data = match(match_id, API_KEY)
        if handle_api_response(temp_data, func_name='match') is None:
            continue
                     
        matches.append(temp_data)
        upload += 1
        total += 1
        
        if upload >= 500:
            thread = send_json(matches.copy())  # Explicit copy
            if thread:
                active_threads.append(thread)
            upload = 0
            matches = []
            print(f"Total matches processed: {total}")
except Exception as e:
    logging.error(f"Error during match processing: {e}")

# Upload remaining matches
if matches:
    thread = send_json(matches)
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