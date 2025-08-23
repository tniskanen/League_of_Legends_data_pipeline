from Utils.S3 import alter_s3_file, check_files
from Utils.api import match
from Utils.json import flatten_json



new_window = {
    'start_epoch': 1753704000,
    'end_epoch': 1753876800
}

bucket = 'lol-match-jsons'
key = 'production/state/next_window.json'
operation = 'overwrite'

alter_s3_file(bucket, key, operation, new_window)







