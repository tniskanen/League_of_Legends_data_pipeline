import logging
import sys

def get_logger(name: str, level=logging.INFO):
    logger = logging.getLogger(name)

    if logger.hasHandlers():
        return logger  # Avoid adding duplicate handlers on repeated calls

    logger.setLevel(level)

    formatter = logging.Formatter(
        fmt="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )

    # Log to a file
    file_handler = logging.FileHandler("api_errors.log")
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    # Log to stdout
    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)

    return logger