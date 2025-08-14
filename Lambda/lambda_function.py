import json
import boto3
import sys
import time

# Test imports immediately and catch any import errors
try:
    print("Testing imports...")
    import mysql.connector
    from Utils.sql import insert_data_to_mysql, ensure_healthy_connection, format_error_response
    from Utils.json import flatten_json, split_json, add_join_keys
    from Utils.S3 import get_parameter_from_ssm
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
    
    logger.info(f"🚀 Starting Lambda execution")
    logger.info(f"📁 Processing: s3://{bucket}/{fileKey}")
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
        s3_object = s3_client.get_object(Bucket=bucket, Key=fileKey)
        file_content = s3_object['Body'].read()
        data = json.loads(file_content.decode('utf-8'))
        logger.info(f"✅ S3 file loaded successfully")

        tables = {
            'BasicStats': [],
            'challengeStats': [],
            'legendaryItem': [],
            'perkMissionStats': []
        }

        logger.info(f"📋 Processing {len(data['matches'])} matches...")
        for game in data['matches']:
            
            for player in game['info']['participants']:

                temp_player = flatten_json(player)

                temp_player['dataVersion'] = game['metadata']['dataVersion']
                temp_player['matchId'] = game['metadata']['matchId']

                temp_player['gameCreation'] = game['info']['gameCreation']
                temp_player['gameDuration'] = game['info']['gameDuration']
                temp_player['gameVersion'] = game['info']['gameVersion']
                temp_player['mapId'] = game['info']['mapId']
                
                # Add source from game data
                if 'source' in game:
                    temp_player['source'] = game['source']
                
                #sorting data for seperate tables, create join keys, add temp dictionaries to data lists
                dicts = add_join_keys(split_json(temp_player))
                tables['BasicStats'].append(dicts[0])
                tables['challengeStats'].append(dicts[1])
                tables['legendaryItem'].append(dicts[2])
                tables['perkMissionStats'].append(dicts[3])
        
        logger.info(f"📊 Data processing complete:")
        logger.info(f"   BasicStats: {len(tables['BasicStats'])} records")
        logger.info(f"   challengeStats: {len(tables['challengeStats'])} records")
        logger.info(f"   legendaryItem: {len(tables['legendaryItem'])} records")
        logger.info(f"   perkMissionStats: {len(tables['perkMissionStats'])} records")
        
        logger.info("🔌 Attempting to connect to MySQL database...")
        try:
            conn = mysql.connector.connect(
                host=DB_HOST,
                user=DB_USER,
                password=DB_PASSWORD,
                database=DB_NAME,
                auth_plugin='mysql_native_password'  # Force native password
            )
            logger.info("✅ Successfully connected to MySQL database")
        except mysql.connector.Error as conn_err:
            logger.error(f"❌ MySQL connection failed: {conn_err}")
            raise

        cursor = conn.cursor() 

        # Define the batch size
        batch_size = 200
        transaction_state = {
            'start_time': time.time(),
            'tables_processed': [],
            'batches_processed': 0,
            'total_records': 0,
            'failed_batches': [],
            'current_table': None,
            'current_batch': None
            }
    
        # Process data in batches
        try:
            # Log initial transaction state
            logger.info("🚀 Starting Transaction:")
            logger.info(f"   Tables to process: {list(tables.keys())}")
            for table_name, table_data in tables.items():
                logger.info(f"   {table_name}: {len(table_data)} records")
            logger.info(f"   Batch size: {batch_size}")
            logger.info(f"   Total records: {sum(len(data) for data in tables.values())}")
            
            conn.start_transaction()  # Start transaction
            
            # Process ALL tables and ALL batches
            for table_name, table_data in tables.items():
                transaction_state['current_table'] = table_name
                transaction_state['total_records'] += len(table_data)
                
                logger.info(f"📋 Processing table: {table_name} ({len(table_data)} records)")
                
                total_batches = (len(table_data) + batch_size - 1) // batch_size
                current_batch_num = 0
                
                for i in range(0, len(table_data), batch_size):
                    current_batch_num += 1
                    batch_data = table_data[i:i + batch_size]
                    batch_start = i
                    batch_end = min(i + batch_size, len(table_data))
                    transaction_state['current_batch'] = f"{batch_start}-{batch_end}"
                    
                    logger.info(f"   📦 Processing batch {current_batch_num}/{total_batches} ({len(batch_data)} records)")
                    
                    conn, cursor = ensure_healthy_connection(conn, cursor)
                    
                    try:
                        insert_data_to_mysql(cursor, table_name, batch_data)
                        transaction_state['batches_processed'] += 1
                        logger.info(f"   ✅ Batch {current_batch_num}/{total_batches} completed")
                    except Exception as e:
                        transaction_state['failed_batches'].append({
                            'table': table_name,
                            'batch_start': batch_start,
                            'batch_end': batch_end,
                            'error': str(e)
                        })
                        logger.error(f"   ❌ Batch {current_batch_num}/{total_batches} failed: {e}")
                        # Decide: rollback entire transaction or continue with other batches
                        raise
                
                transaction_state['tables_processed'].append(table_name)
                logger.info(f"✅ Completed table: {table_name}")
            
            conn.commit()  # Commit everything at once
            logger.info("✅ All data committed successfully")
            
            # Log final transaction state
            transaction_state['end_time'] = time.time()
            transaction_state['duration'] = transaction_state['end_time'] - transaction_state['start_time']
            logger.info("📊 Final Transaction State:")
            logger.info(f"   Duration: {transaction_state['duration']:.2f} seconds")
            logger.info(f"   Tables processed: {len(transaction_state['tables_processed'])}")
            logger.info(f"   Total records: {transaction_state['total_records']}")
            logger.info(f"   Batches processed: {transaction_state['batches_processed']}")
            logger.info(f"   Failed batches: {len(transaction_state['failed_batches'])}")
            
            if transaction_state['failed_batches']:
                logger.warning("⚠️ Failed batches details:")
                for failed_batch in transaction_state['failed_batches']:
                    logger.warning(f"   Table: {failed_batch['table']}, Batch: {failed_batch['batch_start']}-{failed_batch['batch_end']}, Error: {failed_batch['error']}")
            
        except Exception as e:
            conn.rollback()  # Rollback everything on any error
            logger.error(f"❌ Transaction rolled back: {e}")
            
            # Log transaction state at failure
            transaction_state['end_time'] = time.time()
            transaction_state['duration'] = transaction_state['end_time'] - transaction_state['start_time']
            logger.error("📊 Transaction State at Failure:")
            logger.error(f"   Duration: {transaction_state['duration']:.2f} seconds")
            logger.error(f"   Tables processed: {len(transaction_state['tables_processed'])}")
            logger.error(f"   Total records: {transaction_state['total_records']}")
            logger.error(f"   Batches processed: {transaction_state['batches_processed']}")
            logger.error(f"   Failed batches: {len(transaction_state['failed_batches'])}")
            logger.error(f"   Current table: {transaction_state['current_table']}")
            logger.error(f"   Current batch: {transaction_state['current_batch']}")
            
            raise
        
    except (s3_client.exceptions.NoSuchBucket, s3_client.exceptions.NoSuchKey) as e:
        # S3 issues - don't retry
        logger.error(f"S3 Error: {e}")
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
            table=transaction_state.get('current_table'),
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
    logger.info(f"   File processed: s3://{bucket}/{fileKey}")
    logger.info(f"   Total records processed: {transaction_state.get('total_records', 0)}")
    logger.info(f"   Tables processed: {len(transaction_state.get('tables_processed', []))}")
    logger.info(f"   Database transaction time: {transaction_state.get('duration', 0):.2f} seconds")
    logger.info(f"   Total execution time: {execution_time:.2f} seconds")

    return {
            'statusCode': 200,
            'body': json.dumps('data uploaded!')
        }
