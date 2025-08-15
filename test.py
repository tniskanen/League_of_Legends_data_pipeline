from Utils.S3 import alter_s3_file, check_files

new_window = {
    'start_epoch': 1752321600,
    'end_epoch': 1752667200
}

bucket = 'lol-match-jsons'
key = 'production/state/next_window.json'
operation = 'overwrite'

alter_s3_file(bucket, key, operation, new_window)
