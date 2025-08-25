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
    print(f"📊 Batch configuration: 200 matches, 50 timelines")

    # Skip execution if in test mode
    if config.get('source') == 'test':
        print(f"🧪 Test mode detected - skipping {__name__}.py execution")
        print(f"📋 This prevents processing thousands of leftovers during development")
        return

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
        
        print(f"Starting data processing at {time.strftime('%Y-%m-%d %H:%M:%S')}")

        successful_matches = 0
        no_data = 0
        match_data = []
        timeline_data = []
        active_threads = []
        current_index = 0  # Track current position for leftover handling
        
        # Batch counters for progress tracking
        match_batch_count = 0
        timeline_batch_count = 0

        try:
            for i, match_id in enumerate(uniqueMatches):
                current_index = i  # Update current position
                
                # Memory monitoring every 500 matches
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
                    
                    # Create data to upload with unprocessed matches
                    data_to_upload = {
                        "matchlist": unprocessed_matches
                    }
                    
                    # Upload leftovers to S3
                    key = leftover
                    alter_s3_file(config['BUCKET'], key, 'overwrite', data_to_upload)
                    print(f"✅ Data overwritten to {key} with {len(unprocessed_matches)} unprocessed matches")

                    print(f"🛑 Processing stopped due to API key expiration. Processed {i}/{len(uniqueMatches)} matches.")
                    api_expired = True  # Set flag to stop outer loop
                    break
                
                # Progress indicator every 200 matches
                if i % 200 == 0:
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
                successful_matches += 1
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
                
                # Upload every 200 regular matches
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
            logger.error(f"Error during match processing: {e}")
            
            # Handle unprocessed matches due to unexpected error
            if current_index < len(uniqueMatches) - 1:
                unprocessed_matches = list(uniqueMatches)[current_index + 1:]
                print(f"⚠️ Error occurred during processing. Saving {len(unprocessed_matches)} unprocessed matches to S3...")
                
                # Create data to upload with unprocessed matches
                data_to_upload = {
                    "matchlist": unprocessed_matches
                }
                
                # Upload leftovers to S3
                key = leftover
                alter_s3_file(config['BUCKET'], key, 'overwrite', data_to_upload)
                print(f"✅ Data overwritten to {key} with {len(unprocessed_matches)} unprocessed matches")

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

        print(f"{leftover} completed!")
        print(f"Matches with no data: {no_data}")
        print(f"Match batches uploaded: {match_batch_count}")
        print(f"Timeline batches uploaded: {timeline_batch_count}")

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