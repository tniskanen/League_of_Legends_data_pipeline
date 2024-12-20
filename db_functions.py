import requests
import pandas as pd
import time
import sqlite3
import random
import boto3
import json
import threading
from botocore.exceptions import NoCredentialsError, PartialCredentialsError, ClientError
import logging

logging.basicConfig(level=logging.INFO, filename='api_errors.log')

def champion_mastery(puuid, championid, key, retries=3):

    #recursive limit
    if retries <= 0:
        error_info = {
            "championLevel": "Error" + str(mastery['status']['status_code']),
            "championPoints": "Error" + str(mastery['status']['status_code'])
        }
        logging.error(f"Error {mastery['status']['status_code']}: {mastery['status']['message']} From url: {url}")
        print("server error from champion mastery request")
        return error_info
    
    
    url = ('https://na1.api.riotgames.com/lol/champion-mastery/v4/champion-masteries/by-puuid/' + puuid +
            '/by-champion/' + str(championid) +'?api_key=' + key)
    reponse = requests.get(url)
    mastery = reponse.json()

    #check for response errors
    try:
        #check for rate limit and server errors (500-504)
        if mastery['status']['status_code'] >= 429:
            time.sleep(120)
            print("retrying mastery request")
            return(champion_mastery(puuid,championid,key,retries-1))

        #check for client errors or unsupported media errors
        if mastery['status']['status_code'] <= 415:
            error_info = {
                'championLevel': "Error" + str(mastery['status']['status_code']),
                'championPoints': "Error" + str(mastery['status']['status_code'])
            }
            print("client error from mastery request")
            logging.error(f"Error {mastery['status']['status_code']}: {mastery['status']['message']} From url: {url}")
            return error_info
    
    #keyError because 'status' wont be in dictionary
    except KeyError:
        return mastery


def summoner_level(puuid, key, retries=3):

    #recursive limit
    if retries <= 0:
        error_info = {
            "summonerLevel": "Error" + str(summoner_info['status']['status_code']),
            "revisionDate": "Error" + str(summoner_info['status']['status_code'])
        }
        logging.error(f"Error {summoner_info['status']['status_code']}: {summoner_info['status']['message']} From url: {url}")
        print("server error from summoner info request")
        return error_info
        
    url = ('https://na1.api.riotgames.com/lol/summoner/v4/summoners/by-puuid/' + puuid + '?api_key=' + key)
    reponse = requests.get(url)
    summoner_info = reponse.json()

    #check for response errors
    try:
        #check for rate limit errors or 500-504 server errors
        if summoner_info['status']['status_code'] >= 429:
            time.sleep(120)
            print("retrying summoner information request")
            return(summoner_level(puuid,key, retries-1))
        
        #check for client errors, or unathorized requests
        if summoner_info['status']['status_code'] <= 415:
            error_info = {
            "summonerLevel": "Error" + str(summoner_info['status']['status_code']),
            "revisionDate": "Error" + str(summoner_info['status']['status_code'])
            }
            logging.error(f"Error {summoner_info['status']['status_code']}: {summoner_info['status']['message']} From url: {url}")
            print("client error from summoner info request")
            return error_info

    #keyError because 'status' wont be in dictionary
    except KeyError:
        return summoner_info


def matches(puuid,key,retries=3):

    #recursive limit
    if retries <= 0:
        logging.error(f"Error {matchIds['status']['status_code']}: {matchIds['status']['message']} From url: {url}")
        return matchIds
    
    #requesting match Id for 1 game
    url = ('https://americas.api.riotgames.com/lol/match/v5/matches/by-puuid/'
                        +puuid+'/ids?type=ranked&start=0&count=1&api_key='+key)
    response = requests.get(url)
    matchIds = response.json()

    #check for response errors
    try:
        #server errors/limit rate error
        if matchIds['status']['status_code'] >= 429:
            time.sleep(120)
            return(matches(puuid,key,retries-1))
        
        #client errors
        if matchIds['status']['status_code'] <= 415:
            logging.error(f"Error {matchIds['status']['status_code']}: {matchIds['status']['message']} From url: {url}")
            return(matchIds)
        
    #type error because working with lists
    except TypeError:
            return(matchIds) 
        
def data(id,key,retries=3):
    
    #recursive limit
    if retries <= 0:
        logging.error(f"Error {match_data['status']['status_code']}: {match_data['status']['message']} From url: {url}")
        return(match_data)

    #request match data
    url = ('https://americas.api.riotgames.com/lol/match/v5/matches/'+
            id +'?api_key=' + key)
    response = requests.get(url)
    match_data = response.json()

    #check for response errors
    try:
        #server and rate limit errors
        if match_data['status']['status_code'] >= 429:
            time.sleep(120)
            return(data(id,key,retries-1))

        #client errors
        if match_data['status']['status_code'] <= 415:
            logging.error(f"Error {match_data['status']['status_code']}: {match_data['status']['message']} From url: {url}")
            return(match_data)

    #keyError because working with dictionaries
    except KeyError:
        return(match_data)



def upload_to_s3(bucket, key, data):
    try:
        #connect to client
        s3 = boto3.client('s3')
        print('client connection good')
        #upload data
        s3.put_object(Bucket=bucket,Key=key,Body=data)
        print("successful upload of {key}")
    
    except NoCredentialsError:
        print("NoCredentialsError")
    except PartialCredentialsError:
        print("PartialCredentialsError")
    except ClientError as e:
        print("Error uploading to s3")
    except Exception as e:
        print("unexpected Error occured")
    

def send_json(data):

    #convert data into jsons
    json_data = json.dumps(data)

    bucket = 'lol-match-jsons'
    s3_key = f'match_json_objects_{int(time.time())}.json'

    #start upload on new thread
    upload_thread = threading.Thread(target=upload_to_s3, args=(bucket,s3_key,json_data))
    upload_thread.start()

    print("JSON upload is happening in the background...")
    return upload_thread