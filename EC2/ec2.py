import time
import logging
import sys
import os
import psutil  

# Configure logging to output to both file and stdout (for Docker logs)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('api_errors.log'),
        logging.StreamHandler(sys.stdout)
    ]
)

# Basic startup logging
print("🚀 Container Starting - ec2.py")
print(f"Python version: {sys.version}")
print(f"Working directory: {os.getcwd()}")
print(f"PYTHONPATH: {os.environ.get('PYTHONPATH', 'Not set')}")

# Test imports immediately and catch any import errors
try:
    print("Testing imports...")
    from Utils.api import highElo, LowElo, matchList, match, handle_api_response
    from Utils.S3 import send_json, get_api_key_from_ssm
    print("✅ All imports successful")
except ImportError as e:
    print(f"❌ Import error: {e}")
    print("Available modules in current directory:")
    for item in os.listdir('.'):
        print(f"  - {item}")
    sys.exit(1)
except Exception as e:
    print(f"❌ Unexpected import error: {e}")
    sys.exit(1)

start_time = time.time()
start_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

# Get environment variables with logging
MAX_PLAYER_COUNT = int(os.environ.get("PLAYER_LIMIT", 100000))
bucket = os.environ.get("BUCKET_NAME", 'lol-match-jsons')
source = os.environ.get("SOURCE", 'NA')

print(f"Player limit: {MAX_PLAYER_COUNT}")
print(f"S3 bucket: {bucket}")

# Test API key retrieval
print("Retrieving API key from SSM...")
try:
    API_KEY = get_api_key_from_ssm("API_KEY")
    if API_KEY:
        print(f"✅ API key retrieved (length: {len(API_KEY)})")
    else:
        print("❌ Failed to retrieve API key")
        sys.exit(1)
except Exception as e:
    print(f"❌ Error retrieving API key: {e}")
    sys.exit(1)

epochDay = 86400 * 2
low_elo_players = []
high_elo_players = []
matchesList = []
ranks = ['master', 'grandmaster', 'challenger']  
divisions = ['I', 'II', 'III', 'IV']
tiers = ['DIAMOND']
epochTime = int(time.time() - epochDay)

print(f"Starting data collection at {time.strftime('%Y-%m-%d %H:%M:%S')}")

try:
    print("Fetching high elo players...")
    for rank in ranks:
        print(f"  Fetching {rank} players...")
        json_response = highElo(rank, API_KEY)
        if json_response and 'entries' in json_response:
            high_elo_players.extend(json_response['entries'])
            print(f"    Added {len(json_response['entries'])} {rank} players (total: {len(high_elo_players)})")
            if (len(low_elo_players) + len(high_elo_players)) >= MAX_PLAYER_COUNT:
                print(f"    Reached player limit at {rank}")
                break
        else:
            logging.warning(f"No entries found for rank: {rank}")
except Exception as e:
    logging.error(f"Error during highElo request: {e}. KeyErrors indicate incorrect dictionary returned from API. TypeErrors indicate request exceptions.")

try:
    if (len(low_elo_players) + len(high_elo_players)) < MAX_PLAYER_COUNT:
        print("Fetching low elo players...")
        for tier in tiers:
            for division in divisions:
                print(f"  Fetching {tier} {division} players...")
                page = 1
                while True:
                    json_response = LowElo(tier, division, page, API_KEY)
                    if json_response:
                        low_elo_players.extend(json_response)
                        print(f"    Page {page}: Added {len(json_response)} players")
                        page += 1
                    else:
                        print(f"    Finished {tier} {division}")
                        break
                    
                    if (len(low_elo_players) + len(high_elo_players)) >= MAX_PLAYER_COUNT:
                        print(f"    Reached player limit in {tier} {division}")
                        break
                
                if (len(low_elo_players) + len(high_elo_players)) >= MAX_PLAYER_COUNT:
                    break
            if (len(low_elo_players) + len(high_elo_players)) >= MAX_PLAYER_COUNT:
                break

except Exception as e:
    logging.error(f"Error during LowElo request: {e}. KeyErrors indicate incorrect dictionary returned from API. TypeErrors indicate request exceptions.")

print(f"Player collection complete: High={len(high_elo_players)}, Low={len(low_elo_players)}, Total={len(high_elo_players) + len(low_elo_players)}")

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

# Limit player list to the environment-defined max (e.g., 100 for test, 100000 for prod)
ranked_players = normalized_high_elo + normalized_low_elo

player_rank_map = {
    player['puuid']: {
        'tier': player['tier'],
        'rank': player['rank'],
        'lp': player['lp']
    }
    for player in ranked_players if 'puuid' in player
}

ranked_players = ranked_players[:MAX_PLAYER_COUNT]
print(f"Created rank mapping for {len(player_rank_map)} players")
print("Fetching match lists...")

try:
    match_count = 0
    for i, player in enumerate(ranked_players):
        puuid = player.get('puuid')
        if not puuid:
            continue
            
        # Progress indicator every 100 players
        if i % 100 == 0:
            print(f"  Progress: {i}/{len(ranked_players)} players processed, {match_count} matches found")
            
        tempMatches = matchList(player['puuid'], API_KEY, epochTime)
        if isinstance(tempMatches, list):
            matchesList.extend(tempMatches)
            match_count += len(tempMatches)
        else:
            handle_api_response(tempMatches, func_name='matchList', player_id=player['puuid'])
except Exception as e:
    logging.error(f"Error during matchList request: {e}")

uniqueMatches = set(matchesList)
print(f"Found {len(uniqueMatches)} unique matches to process")

successful_matches = 0
total = 0
no_data = 0
matches = []
active_threads = []

print("Processing matches...")

try:
    for i, match_id in enumerate(uniqueMatches):
        # Progress indicator every 100 matches
        if i % 100 == 0:
            print(f"  Progress: {i}/{len(uniqueMatches)} matches processed")
            
        temp_data = match(match_id, API_KEY)
        if handle_api_response(temp_data, func_name='match') is None:
            no_data += 1
            continue
            
        for participant in temp_data['info']['participants']:
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

        temp_data['source'] = source
        matches.append(temp_data)
        successful_matches += 1
        total += 1

        # Upload every 500 successful matches
        if successful_matches % 500 == 0:
            print(f"Uploading batch of {successful_matches} matches to S3 (total processed: {total})")
            thread = send_json(matches.copy(), bucket)  # Explicit copy
            if thread:
                active_threads.append(thread)
            matches = []

except Exception as e:
    logging.error(f"Error during match processing: {e}")

# Upload remaining matches
if matches:
    print(f"Uploading final batch of {len(matches)} matches")
    thread = send_json(matches, bucket)
    if thread:
        active_threads.append(thread)

# Wait for all uploads
print(f"Waiting for {len(active_threads)} upload threads to complete...")
for i, thread in enumerate(active_threads):
    print(f"  Waiting for upload thread {i+1}/{len(active_threads)}")
    thread.join()

print("All uploads completed!")
print(f"Matches with no data: {no_data}")

end_time = time.time()
end_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

print(f"🎉 JOB COMPLETED!")
print(f"Runtime: {end_time - start_time:.2f} seconds")
print(f"Memory usage: {start_memory:.1f}MB -> {end_memory:.1f}MB")
print(f"Total matches processed: {total}")
print(f"Players processed: {len(ranked_players)}")
print(f"Upload batches: {len(active_threads)}")