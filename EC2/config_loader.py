import os
import sys

def load_config():
    # TEST: Force exit code 1 to test backfill exit logic
    # Remove this line after testing
    sys.exit(1)
    
    return {
        "MAX_PLAYER_COUNT": int(os.environ.get("PLAYER_LIMIT", 100000)),
        "start_epoch": os.environ.get("start_epoch"),
        "end_epoch": os.environ.get("end_epoch"),
        "source": os.environ.get("source", 'prod'),
        "API_KEY": os.environ.get("API_KEY"),
        "BUCKET": os.environ.get("BUCKET"),
        "API_KEY_EXPIRATION": os.environ.get("API_KEY_EXPIRATION")
    }