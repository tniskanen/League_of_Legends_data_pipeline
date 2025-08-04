from Utils.logger import get_logger

from config_loader import load_config
from fetcher import run_fetcher
from processor import run_processor
from leftover import run_leftovers

def main():
    config = load_config()
    logger = get_logger(__name__)
    
    logger.info("🎮 Starting container main controller...")

    # Step 1: Fetch matchlist
    matchlist = run_fetcher(config)
    
    # Step 2: Process matchlist (if any)
    if matchlist:
        logger.info("✅ Matchlist fetched successfully, proceeding to match processing.")
        run_processor(config, matchlist)
    else:
        logger.warning("⚠️ No matchlist fetched. Skipping match processing.")

    # Step 3: Always try to process leftovers if time/API allows
    run_leftovers(config)

    logger.info("🎉 Pipeline complete.")

if __name__ == "__main__":
    main()