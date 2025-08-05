import time
import sys
import psutil 

try:
    print("Testing imports...")
    from Utils.api import match, handle_api_response
    from Utils.S3 import send_json, pull_s3_object, upload_to_s3, alter_s3_file
    from Utils.logger import get_logger
    logger = get_logger(__name__)
    print("✅ All imports successful")
except ImportError as e:
    print(f"❌ Import error: {e}")
    print("Available modules in current directory:")
    print(f"🛑 Matchlist processing failed due to import error")
    print(f"📋 Manual intervention required: Check container dependencies")
    sys.exit(7)
except Exception as e:
    print(f"❌ Unexpected import error: {e}")
    print(f"🛑 Matchlist processing failed due to unexpected import error")
    print(f"📋 Manual intervention required: Check container setup")
    sys.exit(7)

def run_processor(config, matchlist):

    print(f"🚀 Running {__name__}.py")
    print(f"Python version: {sys.version}")

    start_time = time.time()
    start_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

    # Retry logic for S3 pull - most failures are temporary
    MAX_RETRIES = 3
    matchlist_data = None
    
    for attempt in range(MAX_RETRIES):
        print(f"📥 Attempting to pull matchlist from S3 (attempt {attempt + 1}/{MAX_RETRIES})...")
        matchlist_data = pull_s3_object(config['BUCKET'], matchlist)
        
        if matchlist_data is not None:
            print(f"✅ Successfully pulled matchlist on attempt {attempt + 1}")
            break
        
        if attempt < MAX_RETRIES - 1:
            print(f"⚠️ Pull failed, waiting 10 seconds before retry...")
            time.sleep(10)
    
    if matchlist_data is None:
        print(f"❌ Failed to pull matchlist from S3 after {MAX_RETRIES} attempts: {matchlist}")
        print(f"⚠️ This could be a temporary S3 issue or corrupted file")
        print(f"🔄 Preserving matchlist and exiting for manual intervention")
        print(f"📋 Manual action required:")
        print(f"   1. Check if {matchlist} exists in S3")
        print(f"   2. If corrupted, regenerate matchlist for epoch {config['start_epoch']} to {config['end_epoch']}")
        print(f"   3. If temporary issue, retry this container")
        print(f"🛑 Exiting with error code 7 - manual intervention needed")
        exit(7)
    
    uniqueMatches = matchlist_data['matchlist']
    player_rank_map = matchlist_data['ranked_map']

    print(f"Starting data processing at {time.strftime('%Y-%m-%d %H:%M:%S')}")

    successful_matches = 0
    total = 0
    no_data = 0
    matches = []
    active_threads = []
    current_index = 0  # Track current position for leftover handling

    try:
        for i, match_id in enumerate(uniqueMatches):
            current_index = i  # Update current position
            # Check API key expiration before processing each match
            current_time = int(time.time())
            if current_time >= int(config['API_KEY_EXPIRATION']):
                print(f"⚠️ API key expired at {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(int(config['API_KEY_EXPIRATION'])))}!")
                print(f"Current time: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(current_time))}")
                
                # Get unprocessed matches (from current index onwards)
                unprocessed_matches = list(uniqueMatches)[i:]
                print(f"Saving {len(unprocessed_matches)} unprocessed matches to S3...")
                
                # Create data to upload with unprocessed matches and player rank map
                data_to_upload = {
                    "ranked_map": player_rank_map,
                    "matchlist": unprocessed_matches
                }
                
                # Upload leftovers to S3
                key = f'backfill/leftovers/leftovers_{config["start_epoch"]}_{config["end_epoch"]}_.json'
                upload_to_s3(config['BUCKET'], key, data_to_upload)
                print(f"✅ Unprocessed matches saved to: {key}")

                print(f"🛑 Processing stopped due to API key expiration. Processed {i}/{len(uniqueMatches)} matches.")
                break
            
            # Progress indicator every 100 matches
            if i % 100 == 0:
                print(f"  Progress: {i}/{len(uniqueMatches)} matches processed")
                
            temp_data = match(match_id, config['API_KEY'])
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

            temp_data['source'] = config['SOURCE']
            matches.append(temp_data)
            successful_matches += 1
            total += 1

            # Upload every 500 successful matches
            if successful_matches % 500 == 0:
                print(f"Uploading batch of {successful_matches} matches to S3 (total processed: {total})")
                thread = send_json(matches.copy(), config['BUCKET'])  # Explicit copy
                if thread:
                    active_threads.append(thread)
                matches = []

    except Exception as e:
        logger.error(f"Error during match processing: {e}")
        
        # Always handle unprocessed matches due to unexpected error
        unprocessed_matches = list(uniqueMatches)[current_index:] if current_index < len(uniqueMatches) else []
        print(f"⚠️ Error occurred during processing. Saving {len(unprocessed_matches)} unprocessed matches to S3...")
        
        # Create data to upload with unprocessed matches and player rank map
        data_to_upload = {
            "ranked_map": player_rank_map,
            "matchlist": unprocessed_matches
        }
        
        # Upload leftovers to S3
        key = f'backfill/leftovers/leftovers_{config["start_epoch"]}_{config["end_epoch"]}_.json'
        upload_to_s3(config['BUCKET'], key, data_to_upload)
        print(f"✅ Unprocessed matches saved to: {key}")

    # Upload remaining matches
    if matches:
        print(f"Uploading final batch of {len(matches)} matches")
        thread = send_json(matches, config['BUCKET'])
        if thread:
            active_threads.append(thread)

    # Wait for all uploads
    print(f"Waiting for {len(active_threads)} upload threads to complete...")
    for i, thread in enumerate(active_threads):
        print(f"  Waiting for upload thread {i+1}/{len(active_threads)}")
        thread.join()

    print("All uploads completed!")
    print(f"Matches with no data: {no_data}")

    # Always delete matchlist - it's either fully processed or stored in leftovers
    alter_s3_file(config['BUCKET'], matchlist, 'delete')
    print(f"✅ Matchlist deleted from S3")
    
    end_time = time.time()
    end_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

    print(f"🎉 JOB COMPLETED!")
    print(f"Runtime: {end_time - start_time:.2f} seconds")
    print(f"Memory usage: {start_memory:.1f}MB -> {end_memory:.1f}MB")
    print(f"Total matches processed: {total}")
    print(f"Upload batches: {len(active_threads)}")
    return