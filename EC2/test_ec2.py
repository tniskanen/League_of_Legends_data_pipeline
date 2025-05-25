from Utils.S3 import send_json, get_api_key_from_ssm, test_aws_credentials
from Utils.api import highElo, matchList, match, handle_api_response
import logging
import time
import os

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def main():
    # Test AWS credentials at startup
    logger.info("Testing AWS credentials...")
    if not test_aws_credentials():
        logger.error("AWS credential test failed, but continuing operation")
    
    # Get API key from SSM Parameter Store
    logger.info("Retrieving API key from SSM Parameter Store...")
    SSM_PARAMETER_NAME = os.environ.get("SSM_PARAMETER_NAME", "API_KEY")
    API_KEY = get_api_key_from_ssm(SSM_PARAMETER_NAME)
    
    if not API_KEY:
        error_msg = "API_KEY not found in SSM Parameter Store"
        logger.error(error_msg)
        raise ValueError(error_msg)
    
    logger.info("API key retrieved successfully")
    
    # Calculate epoch time (24 hours ago)
    epochTime = int(time.time() - 86400)
    matches = []
    
    try:
        logger.info("Fetching high ELO players...")
        json = highElo('challenger', API_KEY)
        player = json['entries'][0]
        
        matchlist = matchList(player['puuid'], API_KEY, epochTime)
        
        for id in matchlist:
            temp = match(id, API_KEY)
            matches.append(temp)
        
        logger.info(f"Sending {len(matches)} matches to S3...")
        thread = send_json(matches)
        thread.join()
        logger.info("Data processing complete")
        
    except Exception as e:
        logger.error(f"Error during data processing: {str(e)}", exc_info=True)
        raise

if __name__ == "__main__":
    main()