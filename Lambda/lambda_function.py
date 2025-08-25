import json
import boto3
import sys
import time
import urllib.parse

# Test imports immediately and catch any import errors
try:
    print("Testing imports...")
    import mysql.connector
    from Utils.sql import insert_data_to_mysql, ensure_healthy_connection, format_error_response
    from Utils.json import flatten_json, flatten_perks, flatten_participant_frames
    from Utils.S3 import get_parameter_from_ssm, send_timeline_events_json
    from Utils.logger import get_logger
    print("✅ All imports successful")
except ImportError as e:
    print(f"❌ Import error: {e}")
    sys.exit(1)
except Exception as e:
    print(f"❌ Unexpected import error: {e}")
    sys.exit(1)

# Use your custom logger utility for consistent formatting across the pipeline
logger = get_logger(__name__)


def lambda_handler(event, context):
    
    # Immediately log the event details for context
    bucket = event['Records'][0]['s3']['bucket']['name']
    fileKey = event['Records'][0]['s3']['object']['key']
    
    # Decode the URL-encoded S3 key
    decoded_fileKey = urllib.parse.unquote(fileKey)
    
    logger.info(f"🚀 Starting Lambda execution")
    logger.info(f"📁 Processing: s3://{bucket}/{decoded_fileKey}")
    logger.info(f"🔍 Original key: {fileKey}")
    logger.info(f"🔍 Decoded key: {decoded_fileKey}")
    logger.info(f"🆔 Request ID: {context.aws_request_id}")
    
    #loading environment variables
    logger.info("Loading database credentials from SSM...")
    try:
        DB_HOST = get_parameter_from_ssm("DB_HOST-dev")
        DB_NAME = get_parameter_from_ssm("DB_NAME-dev")
        DB_USER = get_parameter_from_ssm("DB_USER")
        DB_PASSWORD = get_parameter_from_ssm("DB_PASSWORD-dev")
        
        logger.info(f"DB_HOST: {DB_HOST}")
        logger.info(f"DB_NAME: {DB_NAME}")
        logger.info(f"DB_USER: {DB_USER}")
        logger.info(f"DB_PASSWORD: {'*' * len(DB_PASSWORD) if DB_PASSWORD else 'None'}")  # Mask password
        
        # Validate that we have all required credentials
        if not all([DB_HOST, DB_NAME, DB_USER, DB_PASSWORD]):
            missing = []
            if not DB_HOST: missing.append("DB_HOST-dev")
            if not DB_NAME: missing.append("DB_NAME-dev")
            if not DB_USER: missing.append("DB_USER")
            if not DB_PASSWORD: missing.append("DB_PASSWORD-dev")
            raise ValueError(f"Missing required SSM parameters: {', '.join(missing)}")
            
    except Exception as e:
        logger.error(f"❌ Failed to load SSM parameters: {e}")
        return format_error_response(
            error=e,
            error_type="ssm_parameter_error",
            status_code=500,
            file_key=fileKey,
            bucket=bucket,
            request_id=context.aws_request_id
        )

    s3_client = boto3.client('s3')
    
    # Initialize these variables so they exist for the finally block
    cursor = None
    conn = None

    try:
        logger.info("📥 Downloading and parsing S3 file...")
        s3_object = s3_client.get_object(Bucket=bucket, Key=decoded_fileKey)
        file_content = s3_object['Body'].read()
        data = json.loads(file_content.decode('utf-8'))
        logger.info(f"✅ S3 file loaded successfully")
        print(f"{decoded_fileKey} being processed")
        
        # Debug: Check data structure
        print(f"Data loaded, type: {type(data)}")
        print(f"Data keys: {list(data.keys()) if isinstance(data, dict) else 'Not a dict'}")
        
        # Determine data type and table based on file path
        print("About to process data...")
        if "player-maps" in decoded_fileKey:   
            print("Processing player-maps data")
            table = "player_ranks_data"
            print(f"Table set to: {table}")
            logger.info(f"📊 Processing ranked player data for table: {table}")
            
            # Direct player-maps file (from processor.py upload)
            flattened_players = [
                {"puuid": puuid, **stats}
                for puuid, stats in data.items()
            ]
            all_data = flattened_players
            print(f"Created {len(all_data)} flattened players")
            logger.info(f"📋 Processing {len(all_data)} ranked players")
        
        elif "match_timelines" in decoded_fileKey:
            print("Processing match-timelines data")
            table = "timeline_data"
            print(f"Table set to: {table}")
            logger.info(f"📊 Processing match-timelines data for table: {table}")
            
            all_data = []
            print(f"Found {len(data['matches'])} matches to process")
            logger.info(f"📋 Processing {len(data['matches'])} matches...")

            games_processed = 0
            while data['matches']:
                game = data['matches'].pop(0)
                games_processed += 1
                events = []
                participant_frames = []
                
                # Safely get real_timestamp, with fallback
                try:
                    real_timestamp = game['info']['frames'][0]['events'][0]["realTimestamp"]
                except (IndexError, KeyError):
                    # Fallback to current time if no events or realTimestamp
                    real_timestamp = int(time.time())
                    logger.warning(f"⚠️ No realTimestamp found for match {game['metadata']['matchId']}, using current time")

                #dictionary for participant ids
                lookup = {p['participantId']: p['puuid'] for p in game['info']['participants']}
                match_id = game['metadata']['matchId']
                
                for frame in game['info']['frames']:
                    
                    timestamp = frame['timestamp']

                    events.extend(frame['events'])

                for key, player in frame['participantFrames'].items():
                    temp_player = flatten_participant_frames(player)
                    temp_player['participantId'] = key
                    temp_player['puuid'] = lookup[int(key)]  # Convert string key to int for lookup
                    temp_player['timestamp'] = timestamp
                    temp_player['matchId'] = match_id
                    temp_player['realTimestamp'] = real_timestamp
                    temp_player['endOfGameResult'] = game['info']['endOfGameResult']
                    participant_frames.append(temp_player)
                    
                all_data.extend(participant_frames)

                events.extend(game['info']['participants'])
                events.append(game['info']['endOfGameResult'])
                events.append(game['info']['frameInterval'])
                events.append(real_timestamp)
                events.append(game['metadata']['matchId'])

                # Upload timeline events to S3
                try:
                    # Get the bucket name from environment or use a default
                    timeline_bucket = bucket  # Use the same bucket as the source file
                    
                    # Upload events with date-based folder structure
                    upload_thread = send_timeline_events_json(
                        events_data=events,
                        match_id=match_id,
                        bucket=timeline_bucket,
                        real_timestamp=real_timestamp,
                        source=None  # Set to 'test' if you want test prefix
                    )
                    
                    if upload_thread:
                        logger.info(f"📤 Queued timeline events upload for match {match_id}")
                        print(f"📤 Queued timeline events upload for match {match_id}")
                    else:
                        logger.warning(f"⚠️ Failed to queue timeline events upload for match {match_id}")
                        print(f"⚠️ Failed to queue timeline events upload for match {match_id}")
                        
                except Exception as e:
                    logger.error(f"❌ Error uploading timeline events for match {match_id}: {e}")
                    print(f"❌ Error uploading timeline events for match {match_id}: {e}")
                    # Continue processing other matches even if one fails
                
                # Clear events from memory after upload
                events = None
                
                # Monitor memory every 100 games
                if games_processed % 100 == 0:
                    print(f"Progress: {games_processed} games processed")
                    print(f"Games remaining: {len(data['matches'])}, Participant frames processed: {len(all_data)}")
                    print("---")
            
            # Final summary for timeline processing
            print(f"Timeline processing complete: {games_processed} games processed")
            print(f"Total participant frames: {len(all_data)}")
            print(f"Timeline events uploaded to S3 for each match")
            logger.info(f"📊 Timeline processing complete: {games_processed} games, {len(all_data)} participant frames")

        else:
            print("Processing matches data")
            table = "player_data"
            print(f"Table set to: {table}")
            # Process all matches into a single data list
            logger.info(f"📊 Processing match data for table: {table}")
            
            all_data = []
            print(f"Found {len(data['matches'])} matches to process")
            logger.info(f"📋 Processing {len(data['matches'])} matches...")
            
            # Monitor memory usage
            import psutil
            initial_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB
            print(f"Initial memory usage: {initial_memory:.2f} MB")
            
            games_processed = 0
            while data['matches']:  # While there are games left
                game = data['matches'].pop(0)  # Remove first game
                games_processed += 1
                
                # Process all players in this game
                for player_idx, player in enumerate(game['info']['participants']):
                    # DEBUG: Check enumerate order and player data
                    print(f"DEBUG: Processing player_idx={player_idx}, player keys: {len(player.keys())}")
                    
                    # Create a copy to avoid modifying the original
                    player_copy = player.copy()
                    
                    # DEBUG: Check player_copy keys
                    print(f"DEBUG: Player {player_idx} - player_copy keys: {len(player_copy.keys())}")
                    
                    perks = flatten_perks(player_copy['perks'])
                    del player_copy['perks']
                    
                    # DEBUG: Check perks keys after flattening
                    print(f"DEBUG: Player {player_idx} - perks keys after flatten_perks: {len(perks.keys())}")
                    
                    temp_player = flatten_json(player_copy)
                    
                    # DEBUG: Check temp_player keys after flatten_json
                    print(f"DEBUG: Player {player_idx} - temp_player keys after flatten_json: {len(temp_player.keys())}")
                    
                    # DEBUG: Check what's in each variable
                    print(f"DEBUG: Player {player_idx} - temp_player keys BEFORE update: {list(temp_player.keys())[:10]}...")  # Show first 10 keys
                    print(f"DEBUG: Player {player_idx} - perks keys: {list(perks.keys())}")
                    
                    temp_player.update(perks)
                    
                    # DEBUG: Check what's in temp_player after update
                    print(f"DEBUG: Player {player_idx} - temp_player keys AFTER update: {list(temp_player.keys())[:10]}...")  # Show first 10 keys

                    #remove challenges_ and missions_ from keys
                    cleaned_player = {}
                    for key, value in temp_player.items():
                        if key.startswith("challenges_"):
                            new_key = key.replace("challenges_", "", 1)
                        elif key.startswith("missions_"):
                            new_key = key.replace("missions_", "", 1)
                        else:
                            new_key = key
                        cleaned_player[new_key] = value
                    
                    # DEBUG: Check what's in cleaned_player
                    print(f"DEBUG: Player {player_idx} - cleaned_player keys: {list(cleaned_player.keys())[:10]}...")  # Show first 10 keys
                    print(f"DEBUG: Player {player_idx} - cleaned_player total keys: {len(cleaned_player)}")
                    print("---")

                    cleaned_player['dataVersion'] = game['metadata']['dataVersion']
                    cleaned_player['matchId'] = game['metadata']['matchId']

                    cleaned_player['gameCreation'] = game['info']['gameCreation']
                    cleaned_player['gameDuration'] = game['info']['gameDuration']
                    cleaned_player['gameVersion'] = game['info']['gameVersion']
                    cleaned_player['mapId'] = game['info']['mapId']
                    
                    # Add source from game data
                    if 'source' in game:
                        cleaned_player['source'] = game['source']
                    
                    all_data.append(cleaned_player)
                
                # Game is now completely processed, clear it from memory
                game = None
                
                # Monitor memory every 100 games
                if games_processed % 100 == 0:
                    current_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB
                    memory_change = current_memory - initial_memory
                    print(f"Progress: {games_processed}/{len(data['matches']) + games_processed} games processed")
                    print(f"Memory: {current_memory:.2f} MB (change: {memory_change:+.2f} MB)")
                    print(f"Games remaining: {len(data['matches'])}, Players processed: {len(all_data)}")
                    
                    # Force garbage collection
                    import gc
                    gc.collect()
                    after_gc_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB
                    print(f"Memory after GC: {after_gc_memory:.2f} MB (freed: {current_memory - after_gc_memory:.2f} MB)")
                    print("---")
            
            # Final memory report
            final_memory = psutil.Process().memory_info().rss / 1024 / 1024  # MB
            total_memory_change = final_memory - initial_memory
            print(f"Final memory usage: {final_memory:.2f} MB (total change: {total_memory_change:+.2f} MB)")
            print(f"Total games processed: {games_processed}")
            print(f"Total players processed: {len(all_data)}")
        
        print(f"Data processing complete: {len(all_data)} total records for table '{table}'")
        logger.info(f"📊 Data processing complete: {len(all_data)} total records for table '{table}'")
        
        print("About to connect to database...")
        logger.info("🔌 Attempting to connect to MySQL database...")
        try:
            conn = mysql.connector.connect(
                host=DB_HOST,
                user=DB_USER,
                password=DB_PASSWORD,
                database=DB_NAME,
                auth_plugin='mysql_native_password'  # Force native password
            )
            print("Database connection successful")
            logger.info("✅ Successfully connected to MySQL database")
        except mysql.connector.Error as conn_err:
            print(f"Database connection failed: {conn_err}")
            logger.error(f"❌ MySQL connection failed: {conn_err}")
            raise

        cursor = conn.cursor() 
        print("Cursor created successfully")

        # Define the batch size
        batch_size = 200
        print(f"Batch size set to: {batch_size}")
        transaction_state = {
            'start_time': time.time(),
            'batches_processed': 0,
            'total_records': len(all_data),
            'failed_batches': [],
            'current_batch': None
        }
    
        # Process data in batches
        try:
            print("About to start transaction...")
            # Log initial transaction state
            logger.info("🚀 Starting Transaction:")
            logger.info(f"   Table: {table}")
            logger.info(f"   Total records to process: {len(all_data)}")
            logger.info(f"   Batch size: {batch_size}")
            logger.info(f"   Total batches: {(len(all_data) + batch_size - 1) // batch_size}")
            
            conn.start_transaction()  # Start transaction
            print("Transaction started successfully")
            
            # Process ALL batches
            total_batches = (len(all_data) + batch_size - 1) // batch_size
            current_batch_num = 0
            
            for i in range(0, len(all_data), batch_size):
                current_batch_num += 1
                batch_data = all_data[i:i + batch_size]
                batch_start = i
                batch_end = min(i + batch_size, len(all_data))
                transaction_state['current_batch'] = f"{batch_start}-{batch_end}"
                
                logger.info(f"📦 Processing batch {current_batch_num}/{total_batches} ({len(batch_data)} records) for table '{table}'")
                
                conn, cursor = ensure_healthy_connection(conn, cursor)
                
                try:
                    insert_data_to_mysql(cursor, table, batch_data)  # Single table name
                    transaction_state['batches_processed'] += 1
                    logger.info(f"✅ Batch {current_batch_num}/{total_batches} completed for table '{table}'")
                except Exception as e:
                    transaction_state['failed_batches'].append({
                        'batch_start': batch_start,
                        'batch_end': batch_end,
                        'error': str(e),
                        'table': table
                    })
                    logger.error(f"❌ Batch {current_batch_num}/{total_batches} failed for table '{table}': {e}")
                    # Rollback entire transaction on any batch failure
                    raise
            
            conn.commit()  # Commit everything at once
            logger.info(f"✅ All data committed successfully to table '{table}'")
            
            # Log final transaction state
            transaction_state['end_time'] = time.time()
            transaction_state['duration'] = transaction_state['end_time'] - transaction_state['start_time']
            logger.info("📊 Final Transaction State:")
            logger.info(f"   Table: {table}")
            logger.info(f"   Duration: {transaction_state['duration']:.2f} seconds")
            logger.info(f"   Total records: {transaction_state['total_records']}")
            logger.info(f"   Batches processed: {transaction_state['batches_processed']}")
            logger.info(f"   Failed batches: {len(transaction_state['failed_batches'])}")
            
            if transaction_state['failed_batches']:
                logger.warning("⚠️ Failed batches details:")
                for failed_batch in transaction_state['failed_batches']:
                    logger.warning(f"   Table: {failed_batch['table']}, Batch: {failed_batch['batch_start']}-{failed_batch['batch_end']}, Error: {failed_batch['error']}")
            
        except Exception as e:
            conn.rollback()  # Rollback everything on any error
            logger.error(f"❌ Transaction rolled back for table '{table}': {e}")
            
            # Log transaction state at failure
            transaction_state['end_time'] = time.time()
            transaction_state['duration'] = transaction_state['end_time'] - transaction_state['start_time']
            logger.error("📊 Transaction State at Failure:")
            logger.error(f"   Table: {table}")
            logger.error(f"   Duration: {transaction_state['duration']:.2f} seconds")
            logger.error(f"   Total records: {transaction_state['total_records']}")
            logger.error(f"   Batches processed: {transaction_state['batches_processed']}")
            logger.error(f"   Failed batches: {len(transaction_state['failed_batches'])}")
            logger.error(f"   Current batch: {transaction_state['current_batch']}")
            
            raise
        
    except (s3_client.exceptions.NoSuchBucket, s3_client.exceptions.NoSuchKey) as e:
        # S3 issues - don't retry
        logger.error(f"S3 Error: {e}")
        logger.error(f"Error occurred while processing: {fileKey}")
        return format_error_response(
            error=e,
            error_type="s3_error",
            status_code=404,
            file_key=fileKey,
            bucket=bucket,
            request_id=context.aws_request_id
        )
        
    except mysql.connector.Error as err:
        # Database issues - might retry
        logger.error(f"Database Error: {err}")
        return format_error_response(
            error=err,
            error_type="mysql_error",
            status_code=500,
            file_key=fileKey,
            bucket=bucket,
            request_id=context.aws_request_id,
            batch=transaction_state.get('current_batch')
        )
        
    except KeyError as e:
        # Data structure issues - don't retry
        logger.error(f"Data structure error - missing key: {e}")
        return format_error_response(
            error=e,
            error_type="data_structure_error",
            status_code=400,
            file_key=fileKey,
            bucket=bucket,
            request_id=context.aws_request_id,
            missing_key=str(e)
        )
        
    except Exception as e:
        # Everything else
        logger.error(f"Unexpected Error: {e}")
        return format_error_response(
            error=e,
            error_type="unexpected_error",
            status_code=500,
            file_key=fileKey,
            bucket=bucket,
            request_id=context.aws_request_id
        )
    
    finally:
        # Ensuring resources are closed
        if cursor:
            cursor.close()
        if conn:
            conn.close()

    # Final success summary
    execution_time = time.time() - transaction_state.get('start_time', time.time())
    logger.info("🎉 Lambda execution completed successfully!")
    logger.info(f"📊 Final Summary:")
    logger.info(f"   File processed: s3://{bucket}/{decoded_fileKey}")
    logger.info(f"   Table: {table}")
    logger.info(f"   Total records processed: {transaction_state.get('total_records', 0)}")
    logger.info(f"   Database transaction time: {transaction_state.get('duration', 0):.2f} seconds")
    logger.info(f"   Total execution time: {execution_time:.2f} seconds")
    
    # Add data type specific summary
    if "player-ranks-data" in table:
        logger.info(f"🏆 Ranked player data successfully uploaded to {table}")
    else:
        logger.info(f"🎮 Match data successfully uploaded to {table}")

    return {
            'statusCode': 200,
            'body': json.dumps('data uploaded!')
        }
