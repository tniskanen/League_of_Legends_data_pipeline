import requests
import pandas as pd
import time
import sqlite3
import random
import boto3
import json
import threading
from botocore.exceptions import NoCredentialsError, PartialCredentialsError, ClientError

def champion_mastery(puuid,championid,key):
    while True:
        url = ('https://na1.api.riotgames.com/lol/champion-mastery/v4/champion-masteries/by-puuid/' + puuid +
               '/by-champion/' + str(championid) +'?api_key=' + key)
        reponse = requests.get(url)
        mastery = reponse.json()

        #check for rate limit
        try:
            if mastery['status']['status_code'] == 429:
                time.sleep(120)

            #if no information for a champion, assume there is no mastery
            elif mastery['status']['status_code'] == 404:
                mastery = {
                    'championLevel': 0,
                    'championPoints':0,
                }
                break
        
        #keyError because 'status' wont be in dictionary
        except KeyError:

            break

    return mastery

def summoner_level(puuid,key):
    while True:
        url = ('https://na1.api.riotgames.com/lol/summoner/v4/summoners/by-puuid/' + puuid + '?api_key=' + key)
        reponse = requests.get(url)
        summoner_info = reponse.json()

        #check for rate limit
        try:
            if summoner_info['status']['status_code'] == 429:
                time.sleep(120)

            #if a status code exists thats not rate limit return
            else:
                break
        
        #keyError because 'status' wont be in dictionary
        except KeyError:
            break

    return summoner_info

def matches(puuid,key):
    while True:

        #requesting match Ids
        url = ('https://americas.api.riotgames.com/lol/match/v5/matches/by-puuid/'
                            +puuid+'/ids?type=ranked&start=0&count=20&api_key='+key)
        response = requests.get(url)
        matchIds = response.json()

        #if rate limit exceeded, sleep and re-try request
        try:
            if matchIds['status']['status_code'] == 429:
                time.sleep(120)
            
            #if a status code exists thats not rate limit return
            else:
                break

        #type error because working with lists
        except TypeError:
            break
        
    return(matchIds)  
        
def data(id,key):
    while True:
        #request match data
        response = requests.get('https://americas.api.riotgames.com/lol/match/v5/matches/'+
                                id +'?api_key=' + key)
        match_data = response.json()

        #if rate limit exceeded, sleep
        try:
            if match_data['status']['status_code'] == 429:
                time.sleep(120)
                
            #if a status code exists thats not rate limit return
            else:
                break

        #keyError because working with dictionaries
        except KeyError:
            break
    return(match_data)


#no rate limit issue because there is only 1 request
def grandmasters(key):
    response = requests.get('https://na1.api.riotgames.com/lol/league/v4/grandmasterleagues/by-queue/' + 
                            'RANKED_SOLO_5x5?api_key=' + key)
    summoners = response.json()
    return(summoners)


#no rate limit issue because there is only 1 request
def masters(key):
    response = requests.get('https://na1.api.riotgames.com/lol/league/v4/masterleagues/by-queue/' + 
                            'RANKED_SOLO_5x5?api_key='+key)
    summoners = response.json()
    return(summoners)


def puuid(summoner_id, key):
    while True:
        response = requests.get('https://na1.api.riotgames.com/lol/summoner/v4/summoners/'+
                                summoner_id+'?api_key='+key)
        player = response.json()

        try:

            #fix rate limit error
            if player['status']['status_code'] == 429:
                time.sleep(120)

            #other error that cant be handled with this function
            else:
                break

        #keyError because working with dictionaries
        except KeyError:
            break
    return(player['puuid']) 

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