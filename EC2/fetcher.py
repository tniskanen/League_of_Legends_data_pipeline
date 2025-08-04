import time
import sys
import psutil  

# Test imports immediately and catch any import errors
try:
    print("Testing imports...")
    from Utils.api import highElo, LowElo, matchList 
    from Utils.S3 import handle_api_response, get_parameter_from_ssm, upload_to_s3
    from Utils.logger import get_logger
    logger = get_logger(__name__)
    print("✅ All imports successful")
except ImportError as e:
    print(f"❌ Import error: {e}")
    print("Available modules in current directory:")
    sys.exit(1)
except Exception as e:
    print(f"❌ Unexpected import error: {e}")
    sys.exit(1)


def run_fetcher(config):

# Basic startup logging
    print(f"🚀 Container {__name__}.py")
    print(f"Python version: {sys.version}")

    start_time = time.time()
    start_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

    low_elo_players = []
    high_elo_players = []
    matchesList = []
    ranks = ['master', 'grandmaster', 'challenger']  
    divisions = ['I', 'II', 'III', 'IV']
    tiers = ['DIAMOND']

    print(f"Starting data collection at {time.strftime('%Y-%m-%d %H:%M:%S')}")

    try:
        print("Fetching high elo players...")
        for rank in ranks:
            print(f"  Fetching {rank} players...")
            json_response = highElo(rank, config['API_KEY'])
            if json_response and 'entries' in json_response:
                high_elo_players.extend(json_response['entries'])
                print(f"    Added {len(json_response['entries'])} {rank} players (total: {len(high_elo_players)})")
                if (len(low_elo_players) + len(high_elo_players)) >= config['MAX_PLAYER_COUNT']:
                    print(f"    Reached player limit at {rank}")
                    break
            else:
                logger.warning(f"No entries found for rank: {rank}")
    except Exception as e:
        logger.error(f"Error during highElo request: {e}. KeyErrors indicate incorrect dictionary returned from API. TypeErrors indicate request exceptions.")

    try:
        if (len(low_elo_players) + len(high_elo_players)) < config['MAX_PLAYER_COUNT']:
            print("Fetching low elo players...")
            for tier in tiers:
                for division in divisions:
                    print(f"  Fetching {tier} {division} players...")
                    page = 1
                    while True:
                        json_response = LowElo(tier, division, page, config['API_KEY'])
                        if json_response:
                            low_elo_players.extend(json_response)
                            print(f"    Page {page}: Added {len(json_response)} players")
                            page += 1
                        else:
                            print(f"    Finished {tier} {division}")
                            break
                        
                        if (len(low_elo_players) + len(high_elo_players)) >= config['MAX_PLAYER_COUNT']:
                            print(f"    Reached player limit in {tier} {division}")
                            break
                    
                    if (len(low_elo_players) + len(high_elo_players)) >= config['MAX_PLAYER_COUNT']:
                        break
                if (len(low_elo_players) + len(high_elo_players)) >= config['MAX_PLAYER_COUNT']:
                    break

    except Exception as e:
        logger.error(f"Error during LowElo request: {e}. KeyErrors indicate incorrect dictionary returned from API. TypeErrors indicate request exceptions.")

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

    ranked_players = ranked_players[:config['MAX_PLAYER_COUNT']]
    print(f"Created rank mapping for {len(player_rank_map)} players")
    print("Fetching match lists...")

    try:
        match_count = 0
        for i, player in enumerate(ranked_players):
            puuid = player.get('puuid')
            if not puuid:
                continue
                
            # Progress indicator every 1000 players
            if i % 1000 == 0:
                print(f"  Progress: {i}/{len(ranked_players)} players processed, {match_count} matches found")
                
            tempMatches = matchList(player['puuid'], config['start_epoch'], config['end_epoch'], config['API_KEY'])
            if isinstance(tempMatches, list):
                matchesList.extend(tempMatches)
                match_count += len(tempMatches)
            else:
                handle_api_response(tempMatches, func_name='matchList', player_id=player['puuid'])
    except Exception as e:
        logger.error(f"Error during matchList request: {e}")

    uniqueMatches = set(matchesList)
    print(f"Found {len(uniqueMatches)} unique matches to process")

    key = f'backfill/matchlists/match_ids_{config["start_epoch"]}_{config["end_epoch"]}_.json'

    data_to_upload = {
        "ranked_map": player_rank_map,
        "matchlist": uniqueMatches
    }

    upload_to_s3(config['BUCKET'], key, data_to_upload)

    end_time = time.time()
    end_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

    print(f"🎉 JOB COMPLETED!")
    print(f"Runtime: {end_time - start_time:.2f} seconds")
    print(f"Memory usage: {start_memory:.1f}MB -> {end_memory:.1f}MB")
    print(f"Players processed: {len(ranked_players)}")
    print(f"Total matches produced: {len(uniqueMatches)}")
    return key
