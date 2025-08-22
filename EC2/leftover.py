import time
import sys
import psutil 

try:
    print("Testing imports...")
    from Utils.api import match, match_timeline, handle_api_response
    from Utils.S3 import send_match_json, pull_s3_object, alter_s3_file, check_files
    from Utils.logger import get_logger
    logger = get_logger(__name__)
    print("✅ All imports successful")
except ImportError as e:
    print(f"❌ Import error: {e}")
    print("Available modules in current directory:")
    print(f"🛑 Leftover processing failed due to import error")
    print(f"📋 Skipping this window - no data loss, moving to next window")
    sys.exit(8)
except Exception as e:
    print(f"❌ Unexpected import error: {e}")
    print(f"🛑 Leftover processing failed due to unexpected import error")
    print(f"📋 Skipping this window - no data loss, moving to next window")
    sys.exit(8)

def run_leftovers(config):

    print(f"🚀 Running {__name__}.py")
    print(f"Python version: {sys.version}")

    start_time = time.time()
    start_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

    leftovers = check_files(config['BUCKET'], 'backfill/leftovers/')
    if len(leftovers) == 0:
        print(f"No leftovers found, skipping {__name__}.py")
        return
    
    total = 0
    api_expired = False  # Flag to track API expiration
    
    for leftover in leftovers:
        if api_expired:  # Skip remaining leftovers if API expired
            print(f"⚠️ Skipping {leftover} due to API key expiration")
            continue
        leftover_data = pull_s3_object(config['BUCKET'], leftover) 
        uniqueMatches = leftover_data['matchlist']
        leftover_data_collection_type = leftover_data['data_collection_type']
        
        # Set function based on leftover's data collection type
        if leftover_data_collection_type == "match_timeline":
            func = match_timeline
        else:
            func = match

        print(f"Starting data processing at {time.strftime('%Y-%m-%d %H:%M:%S')}")

        successful_matches = 0
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
                    unprocessed_matches = list(uniqueMatches)[i + 1:]
                    print(f"Saving {len(unprocessed_matches)} unprocessed matches to S3...")
                    
                    # Create data to upload with unprocessed matches and data collection type
                    data_to_upload = {
                        "data_collection_type": leftover_data_collection_type,
                        "matchlist": unprocessed_matches
                    }
                    
                    # Upload leftovers to S3
                    key = leftover
                    alter_s3_file(config['BUCKET'], key, 'overwrite', data_to_upload)
                    print(f"✅ Data overwritten to {key} with {len(unprocessed_matches)} unprocessed matches")

                    print(f"🛑 Processing stopped due to API key expiration. Processed {i}/{len(uniqueMatches)} matches.")
                    api_expired = True  # Set flag to stop outer loop
                    break
                
                # Progress indicator every 100 matches
                if i % 100 == 0:
                    print(f"  Progress: {i}/{len(uniqueMatches)} matches processed")
                    
                temp_data = func(match_id, config['API_KEY'])
                if handle_api_response(temp_data, func_name='match') is None:
                    no_data += 1
                    continue

                temp_data['source'] = config['source']
                matches.append(temp_data)
                successful_matches += 1
                total += 1

                # Upload every 500 successful matches
                if successful_matches % 500 == 0:
                    print(f"Uploading batch of {successful_matches} matches to S3 (total processed: {total})")
                    thread = send_match_json(data=matches.copy(), bucket=config['BUCKET'], source=config['source'], data_collection_type=leftover_data_collection_type)  # Explicit copy
                    if thread:
                        active_threads.append(thread)
                    matches = []

        except Exception as e:
            logger.error(f"Error during match processing: {e}")
            
            # Handle unprocessed matches due to unexpected error
            if current_index < len(uniqueMatches) - 1:
                unprocessed_matches = list(uniqueMatches)[current_index + 1:]
                print(f"⚠️ Error occurred during processing. Saving {len(unprocessed_matches)} unprocessed matches to S3...")
                
                # Create data to upload with unprocessed matches and data collection type
                data_to_upload = {
                    "data_collection_type": leftover_data_collection_type,
                    "matchlist": unprocessed_matches
                }
                
                # Upload leftovers to S3
                key = leftover
                alter_s3_file(config['BUCKET'], key, 'overwrite', data_to_upload)
                print(f"✅ Data overwritten to {key} with {len(unprocessed_matches)} unprocessed matches")

        # Upload remaining matches
        if matches:
            print(f"Uploading final batch of {len(matches)} matches")
            thread = send_match_json(data=matches, bucket=config['BUCKET'], source=config['source'], data_collection_type=leftover_data_collection_type)
            if thread:
                active_threads.append(thread)

        # Wait for all uploads
        print(f"Waiting for {len(active_threads)} upload threads to complete...")
        for i, thread in enumerate(active_threads):
            print(f"  Waiting for upload thread {i+1}/{len(active_threads)}")
            thread.join()

        print(f"{leftover} completed!")
        print(f"Matches with no data: {no_data}")

        # Check if this leftover file was completely processed
        if current_index >= len(uniqueMatches) - 1 and not api_expired:
            # All matches processed - delete the leftover file
            alter_s3_file(config['BUCKET'], leftover, 'delete')
            print(f"✅ Leftover completely processed and deleted from S3")
        else:
            # Not fully processed - file was already overwritten with remaining data
            print(f"⚠️ Leftover not fully processed (completed: {current_index + 1}/{len(uniqueMatches)}, API expired: {api_expired})")
            print(f"📝 File was overwritten with remaining unprocessed matches")
    
    
    print(f"Total matches processed: {total}")
    end_time = time.time()
    end_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB

    print(f"🎉 JOB COMPLETED!")
    print(f"Runtime: {end_time - start_time:.2f} seconds")
    print(f"Memory usage: {start_memory:.1f}MB -> {end_memory:.1f}MB")
    print(f"Total matches processed: {total}")
    print(f"Upload batches: {len(active_threads)}")
    return