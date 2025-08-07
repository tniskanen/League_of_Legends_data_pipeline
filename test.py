from Utils.S3 import alter_s3_file

new_window = {
    'start_epoch': 1753617600,
    'end_epoch': 1753963200
}

bucket = 'lol-match-jsons'
key = 'production/state/next_window.json'
operation = 'overwrite'

alter_s3_file(bucket, key, operation, new_window)