import sys
from Utils.logger import get_logger

from config_loader import load_config
from fetcher import run_fetcher
from processor import run_processor
from leftover import run_leftovers

def main():
    config = load_config()
    logger = get_logger(__name__)
    
    logger.info("🎮 Starting container main controller...")
    
    try:
        # Step 1: Fetch matchlist
        matchlist = run_fetcher(config)
        
        # Step 2: Process matchlist (if any)
        if matchlist:
            logger.info("✅ Matchlist fetched successfully, proceeding to match processing.")
            run_processor(config, matchlist)
        else:
            logger.warning("⚠️ No matchlist fetched. Skipping match processing.")

        # Step 3: Always try to process leftovers if time/API allows
        try:
            run_leftovers(config)
        except Exception as e:
            print(f"⚠️ Leftover processing failed: {e}")
            print(f"⚠️ Exception type: {type(e).__name__}")
            print(f"⚠️ Exception details: {str(e)}")
            import traceback
            print(f"⚠️ Full traceback: {traceback.format_exc()}")
            print("📋 Continuing with pipeline completion - leftover errors are non-critical")
        
        logger.info("🎉 Pipeline complete.")
        
    except SystemExit as e:
        # Re-raise SystemExit to preserve exit code
        raise
    except Exception as e:
        print(f"❌ UNEXPECTED ERROR: {e}")
        print(f"❌ Exception type: {type(e).__name__}")
        print(f"❌ Exception details: {str(e)}")
        import traceback
        print(f"❌ Full traceback: {traceback.format_exc()}")
        sys.exit(1)  # Critical failure

if __name__ == "__main__":
    main()