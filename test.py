from Utils.S3 import alter_s3_file, check_files
from Utils.api import match
from Utils.json import flatten_json


'''
new_window = {
    'start_epoch': 1752321600,
    'end_epoch': 1752667200
}

bucket = 'lol-match-jsons'
key = 'production/state/next_window.json'
operation = 'overwrite'

alter_s3_file(bucket, key, operation, new_window)
'''

api_key = "RGAPI-8fefcb7e-6fb6-4e7b-bfe2-6bf3745bdba8"
match_id = "NA1_4808089757"

match_data = match(match_id, api_key)

player_test_data = match_data['info']['participants'][0]

def flatten_perks(perks):

    out = {}

    Primary  = {}
    for i, perk in enumerate(perks['styles'][0]['selections']):
        Primary[f"slot_{i+1}"] = perk
    Primary['style'] = perks['styles'][0]['style']
    
    Secondary = {}
    for i, perk in enumerate(perks['styles'][1]['selections']):
        Secondary[f"slot_{i+1}"] = perk
    Secondary['style'] = perks['styles'][1]['style']

    out['Primary'] = Primary
    out['Secondary'] = Secondary
    out['statPerks'] = perks['statPerks']
    
    
    print(flatten_json(out))

flatten_perks(player_test_data['perks'])





