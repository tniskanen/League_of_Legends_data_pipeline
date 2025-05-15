from Utils.S3 import send_json, get_api_key_from_ssm
from Utils.api import highElo, matchList, match, handle_api_response

#environment variables
API_KEY = get_api_key_from_ssm("API_KEY")
print(API_KEY)