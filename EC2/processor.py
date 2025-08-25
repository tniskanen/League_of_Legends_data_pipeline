import time
import sys
import psutil 

try:
    print("Testing imports...")
    from Utils.api import match, match_timeline, handle_api_response
    from Utils.S3 import send_match_json, pull_s3_object, upload_to_s3, alter_s3_file
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
    print(f"Exception type: {type(e).__name__}")
    print(f"Exception details: {str(e)}")
    import traceback
    print(f"Full traceback: {traceback.format_exc()}")
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

    print(f"🔍 DEBUG: Found {len(uniqueMatches)} matches to process")
    print(f"📊 Batch configuration: 200 matches, 50 timelines")

    #uploading matchlist to s3
    try:
        print(f"📤 DEBUG: Starting player-map upload...")
        pm_key = f'player-maps/player-map_{config["start_epoch"]}_{config["end_epoch"]}_.json'
        upload_to_s3(config['BUCKET'], pm_key, player_rank_map)
        print(f"✅ player-map uploaded to: {pm_key}")
    except Exception as e:
        print(f"❌ CRITICAL: Failed to upload player-map: {e}")
        print(f"🛑 Cannot proceed without player-map - exiting with error")
        sys.exit(1)  # Critical failure - exit code 1

    print(f"Starting data processing at {time.strftime('%Y-%m-%d %H:%M:%S')}")

    total = 0
    no_data = 0
    match_data = []
    timeline_data = []
    active_threads = []
    current_index = 0  # Track current position for leftover handling
    
    # Batch counters for progress tracking
    match_batch_count = 0
    timeline_batch_count = 0

    try:
        print(f"🔄 DEBUG: Starting main processing loop with {len(uniqueMatches)} matches...")
        for i, match_id in enumerate(uniqueMatches):
            current_index = i  # Update current position
            
            # Memory monitoring every 500 matches (reduced from every 10)
            if i % 500 == 0:
                current_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB
                print(f"🔍 Memory check: {current_memory:.2f} MB (match {i+1}/{len(uniqueMatches)})")
            
            # Check API key expiration before processing each match
            current_time = int(time.time())
            if current_time >= int(config['API_KEY_EXPIRATION']):
                print(f"⚠️ API key expired at {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(int(config['API_KEY_EXPIRATION'])))}!")
                print(f"Current time: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(current_time))}")
                
                # Get unprocessed matches (from current index onwards)
                unprocessed_matches = list(uniqueMatches)[i + 1:]
                print(f"Saving {len(unprocessed_matches)} unprocessed matches to S3...")
                
                # Create data to upload with unprocessed matches and data collection type
                data_to_upload = {
                    "matchlist": unprocessed_matches
                }
                
                # Upload leftovers to S3
                key = f'backfill/leftovers/leftovers_{config["start_epoch"]}_{config["end_epoch"]}_{len(unprocessed_matches)}_matches.json'
                upload_to_s3(config['BUCKET'], key, data_to_upload)
                print(f"✅ Unprocessed matches saved to: {key}")

                print(f"🛑 Processing stopped due to API key expiration. Processed {i}/{len(uniqueMatches)} matches.")
                break
            
            # Progress indicator every 1000 matches
            if i % 1000 == 0:
                print(f"  Progress: {i}/{len(uniqueMatches)} matches processed")
                
            temp_data_match = match(match_id, config['API_KEY'])
            temp_data_timeline = match_timeline(match_id, config['API_KEY'])
            
            if handle_api_response(temp_data_match, func_name='match') is None:
                no_data += 1
                continue
            if handle_api_response(temp_data_timeline, func_name='match_timeline') is None:
                no_data += 1
                continue

            temp_data_match['source'] = config['source']
            temp_data_timeline['source'] = config['source']
            match_data.append(temp_data_match)
            timeline_data.append(temp_data_timeline)
            total += 1

            # Upload every 50 timeline matches (smaller batch due to larger data size)
            if len(timeline_data) >= 50:
                timeline_batch_count += 1
                print(f"📤 Uploading batch #{timeline_batch_count} of {len(timeline_data)} timeline data to S3 (total processed: {total})")
                
                thread = send_match_json(data=timeline_data.copy(), bucket=config['BUCKET'], source=config['source'], data_collection_type="match_timeline")
                if thread:
                    active_threads.append(thread)
                
                timeline_data = []  # Clear memory immediately
                
                # Force garbage collection
                import gc
                gc.collect()
            
            # Upload every 200 regular matches (adjusted batch size)
            if len(match_data) >= 200:
                match_batch_count += 1
                print(f"📤 Uploading batch #{match_batch_count} of {len(match_data)} match data to S3 (total processed: {total})")
                
                thread = send_match_json(data=match_data.copy(), bucket=config['BUCKET'], source=config['source'], data_collection_type="match")
                if thread:
                    active_threads.append(thread)
                
                match_data = []  # Clear memory immediately
                
                # Force garbage collection
                import gc
                gc.collect()

    except Exception as e:
        print(f"❌ ERROR during match processing: {e}")
        print(f"❌ Exception type: {type(e).__name__}")
        print(f"❌ Exception details: {str(e)}")
        import traceback
        print(f"❌ Full traceback: {traceback.format_exc()}")
        
        # Always handle unprocessed matches due to unexpected error
        unprocessed_matches = list(uniqueMatches)[current_index + 1:] if current_index < len(uniqueMatches) - 1 else []
        print(f"⚠️ Error occurred during processing. Saving {len(unprocessed_matches)} unprocessed matches to S3...")
        
        # Create data to upload with unprocessed matches and data collection type
        data_to_upload = {
            "matchlist": unprocessed_matches
        }
        
        # Upload leftovers to S3
        key = f'backfill/leftovers/leftovers_{config["start_epoch"]}_{config["end_epoch"]}_{len(unprocessed_matches)}_matches.json'
        upload_to_s3(config['BUCKET'], key, data_to_upload)
        print(f"✅ Unprocessed matches saved to: {key}")

    print(f"🔍 DEBUG: Main processing loop completed. match_data: {len(match_data)}, timeline_data: {len(timeline_data)}, total: {total}")

    # Upload remaining match data
    if match_data:
        match_batch_count += 1
        print(f"📤 Uploading final batch #{match_batch_count} of {len(match_data)} match data...")
        thread = send_match_json(data=match_data, bucket=config['BUCKET'], source=config['source'], data_collection_type="match")
        if thread:
            active_threads.append(thread)
        print(f"✅ Final match data batch upload thread created")
        
        # Clear match_data after final upload
        match_data = []
        import gc
        gc.collect()
    else:
        print(f"ℹ️ No final match data batch to upload (match_data list is empty)")

    # Upload remaining timeline data
    if timeline_data:
        timeline_batch_count += 1
        print(f"📤 Uploading final batch #{timeline_batch_count} of {len(timeline_data)} timeline data...")
        thread = send_match_json(data=timeline_data, bucket=config['BUCKET'], source=config['source'], data_collection_type="match_timeline")
        if thread:
            active_threads.append(thread)
        print(f"✅ Final timeline data batch upload thread created")
        
        # Clear timeline_data after final upload
        timeline_data = []
        import gc
        gc.collect()
    else:
        print(f"ℹ️ No final timeline data batch to upload (timeline_data list is empty)")

    # Wait for all uploads
    print(f"⏳ Waiting for {len(active_threads)} upload threads to complete...")
    
    for i, thread in enumerate(active_threads):
        thread.join()
        print(f"✅ Upload thread {i+1}/{len(active_threads)} completed")

    print("All uploads completed!")
    print(f"Matches with no data: {no_data}")
    print(f"Match batches uploaded: {match_batch_count}")
    print(f"Timeline batches uploaded: {timeline_batch_count}")

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
    print(f"Batch breakdown: {match_batch_count} match batches, {timeline_batch_count} timeline batches")
    return