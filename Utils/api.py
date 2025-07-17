import requests
import logging 
import time
import random
from typing import Dict, Optional

logging.basicConfig(level=logging.INFO, filename='api_errors.log')

class RateLimitHandler:
    def __init__(self):
        self.request_times = []
        self.personal_rate_limit_reset = 0
        self.service_rate_limit_reset = 0
    
    def handle_rate_limit_response(self, response: requests.Response) -> int:
        """
        Handle rate limit response and return appropriate wait time
        Returns wait time in seconds
        """
        # Check for Retry-After header (most reliable)
        retry_after = response.headers.get('Retry-After')
        if retry_after:
            wait_time = int(retry_after)
            logging.info(f"Rate limited - Retry-After header indicates {wait_time}s wait")
            return wait_time
        
        # Check for X-Rate-Limit headers (common pattern)
        rate_limit_type = response.headers.get('X-Rate-Limit-Type', 'unknown')
        
        if response.status_code == 429:
            if rate_limit_type == 'personal':
                # Personal rate limit - usually shorter
                wait_time = 1  # Start with 1 second
                logging.info(f"Personal rate limit hit - waiting {wait_time}s")
            elif rate_limit_type == 'service':
                # Service rate limit - usually longer
                wait_time = 30  # More conservative for service limits
                logging.info(f"Service rate limit hit - waiting {wait_time}s")
            else:
                # Unknown rate limit type - be conservative
                wait_time = 10
                logging.info(f"Unknown rate limit type - waiting {wait_time}s")
        else:
            # Server error (500+) - exponential backoff
            wait_time = min(60, 2 ** (3 - 1))  # Cap at 60 seconds
            logging.info(f"Server error {response.status_code} - waiting {wait_time}s")
        
        return wait_time

    def exponential_backoff(self, attempt: int, base_delay: float = 1.0, max_delay: float = 60.0) -> float:
        """
        Calculate exponential backoff with jitter
        """
        delay = min(base_delay * (2 ** attempt), max_delay)
        # Add jitter to prevent thundering herd
        jitter = random.uniform(0.1, 0.3) * delay
        return delay + jitter

rate_limiter = RateLimitHandler()

def make_api_request_with_smart_backoff(url: str, max_retries: int = 3) -> Optional[Dict]:
    """
    Make API request with intelligent retry logic
    """
    for attempt in range(max_retries):
        try:
            response = requests.get(url)
            
            # Success case
            if response.status_code == 200:
                return response.json()
            
            # Rate limit or server error
            elif response.status_code >= 429:
                if attempt == max_retries - 1:
                    logging.error(f"Max retries exceeded for {url}")
                    return None
                
                # Smart wait time calculation
                if response.status_code == 429:
                    wait_time = rate_limiter.handle_rate_limit_response(response)
                else:
                    wait_time = rate_limiter.exponential_backoff(attempt)
                
                logging.info(f"Waiting {wait_time:.1f}s before retry {attempt + 1}/{max_retries}")
                time.sleep(wait_time)
                continue
            
            # Client errors (400-428) - don't retry
            elif 400 <= response.status_code < 429:
                logging.error(f"Client error {response.status_code} for {url}: {response.text}")
                return None
                
        except requests.exceptions.RequestException as e:
            if attempt == max_retries - 1:
                logging.error(f"Request failed after {max_retries} attempts: {e}")
                return None
            
            wait_time = rate_limiter.exponential_backoff(attempt)
            logging.info(f"Request exception, waiting {wait_time:.1f}s: {e}")
            time.sleep(wait_time)
    
    return None

# Updated functions using smart backoff
def highElo(rank: str, key: str, retries: int = 3) -> Optional[Dict]:
    """Enhanced highElo with smart rate limiting"""
    url = f'https://na1.api.riotgames.com/lol/league/v4/{rank}leagues/by-queue/RANKED_SOLO_5x5?api_key={key}'
    return make_api_request_with_smart_backoff(url, retries)

def LowElo(rank: str, division: str, page: int, key: str, retries: int = 3) -> Optional[Dict]:
    """Enhanced highElo with smart rate limiting"""
    url = f'https://na1.api.riotgames.com/lol/league/v4/entries/RANKED_SOLO_5x5/{rank}/{division}?page={page}&api_key={key}'
    return make_api_request_with_smart_backoff(url, retries)

def matchList(puuid: str, key: str, epochTime: int, retries: int = 3) -> Optional[Dict]:
    """Enhanced matchList with smart rate limiting"""
    url = f'https://americas.api.riotgames.com/lol/match/v5/matches/by-puuid/{puuid}/ids?startTime={epochTime}&queue=420&type=ranked&start=0&count=100&api_key={key}'
    return make_api_request_with_smart_backoff(url, retries)

def match(match_id: str, key: str, retries: int = 3) -> Optional[Dict]:
    """Enhanced match with smart rate limiting"""
    url = f'https://americas.api.riotgames.com/lol/match/v5/matches/{match_id}?api_key={key}'
    return make_api_request_with_smart_backoff(url, retries)

# Example with even more advanced features
class AdvancedRateLimiter:
    def __init__(self):
        self.request_history = []
        self.rate_limits = {
            'personal': {'requests': 100, 'window': 120},  # 100 requests per 2 minutes
            'method': {'requests': 500, 'window': 600}     # 500 requests per 10 minutes
        }
    
    def can_make_request(self) -> bool:
        """Check if we can make a request without hitting rate limits"""
        current_time = time.time()
        
        # Clean old requests from history
        self.request_history = [
            req_time for req_time in self.request_history 
            if current_time - req_time < 600  # Keep 10 minutes of history
        ]
        
        # Check against rate limits
        for limit_type, config in self.rate_limits.items():
            recent_requests = [
                req_time for req_time in self.request_history
                if current_time - req_time < config['window']
            ]
            
            if len(recent_requests) >= config['requests']:
                oldest_request = min(recent_requests)
                wait_time = config['window'] - (current_time - oldest_request)
                logging.info(f"Pre-emptive rate limit prevention: waiting {wait_time:.1f}s")
                return False
        
        return True
    
    def record_request(self):
        """Record that a request was made"""
        self.request_history.append(time.time())

# Circuit breaker pattern for handling repeated failures
class CircuitBreaker:
    def __init__(self, failure_threshold: int = 5, recovery_timeout: int = 60):
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self.failure_count = 0
        self.last_failure_time = None
        self.state = 'CLOSED'  # CLOSED, OPEN, HALF_OPEN
    
    def can_execute(self) -> bool:
        if self.state == 'CLOSED':
            return True
        elif self.state == 'OPEN':
            if time.time() - self.last_failure_time > self.recovery_timeout:
                self.state = 'HALF_OPEN'
                return True
            return False
        elif self.state == 'HALF_OPEN':
            return True
    
    def on_success(self):
        self.failure_count = 0
        self.state = 'CLOSED'
    
    def on_failure(self):
        self.failure_count += 1
        self.last_failure_time = time.time()
        
        if self.failure_count >= self.failure_threshold:
            self.state = 'OPEN'
            logging.warning(f"Circuit breaker opened after {self.failure_count} failures")

def handle_api_response(response, func_name, player_id=None):
    """Enhanced response handler"""
    if response is None:
        logging.warning(f"Request error in {func_name} function for player {player_id}")
        return None
    if isinstance(response, dict) and 'status' in response:
        logging.error(f"Error from {func_name} function: {response['status']['status_code']} for player {player_id}")
        return None
    
def champion_mastery(puuid, championid, key, retries=3):
    mastery = None
    url = None  # Initialize url variable

    # Recursive limit
    if retries <= 0:
        error_info = {
            "championLevel": "Error",
            "championPoints": "Error"
        }
        if mastery and 'status' in mastery:
            error_info["championLevel"] = f"Error{mastery['status']['status_code']}"
            error_info["championPoints"] = f"Error{mastery['status']['status_code']}"
            logging.error(f"Error {mastery['status']['status_code']}: {mastery['status']['message']} From url: {url}")
        else:
            logging.error(f"Failed to retrieve champion mastery for puuid {puuid} after all retries")
        print("server error from champion mastery request")
        return error_info
    
    try:
        url = ('https://na1.api.riotgames.com/lol/champion-mastery/v4/champion-masteries/by-puuid/' + puuid +
                '/by-champion/' + str(championid) +'?api_key=' + key)
        response = requests.get(url)  # Fixed typo: reponse -> response
        mastery = response.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        time.sleep(120)
        return champion_mastery(puuid, championid, key, retries-1)

    # Check for response errors
    try:
        # Check for rate limit and server errors (500-504)
        if mastery['status']['status_code'] >= 429:
            time.sleep(120)
            print("retrying mastery request")
            return champion_mastery(puuid, championid, key, retries-1)

        # Check for client errors or unsupported media errors
        if mastery['status']['status_code'] <= 415:
            error_info = {
                'championLevel': f"Error{mastery['status']['status_code']}",
                'championPoints': f"Error{mastery['status']['status_code']}"
            }
            print("client error from mastery request")
            logging.error(f"Error {mastery['status']['status_code']}: {mastery['status']['message']} From url: {url}")
            return error_info
    
    # KeyError because 'status' won't be in dictionary (successful response)
    except KeyError:
        return mastery

def summoner_level(puuid, key, retries=3):
    summoner_info = None
    url = None  # Initialize url variable

    # Recursive limit
    if retries <= 0:
        error_info = {
            "summonerLevel": "Error",
            "revisionDate": "Error"
        }
        if summoner_info and 'status' in summoner_info:
            error_info["summonerLevel"] = f"Error{summoner_info['status']['status_code']}"
            error_info["revisionDate"] = f"Error{summoner_info['status']['status_code']}"
            logging.error(f"Error {summoner_info['status']['status_code']}: {summoner_info['status']['message']} From url: {url}")
        else:
            logging.error(f"Failed to retrieve summoner info for puuid {puuid} after all retries")
        print("server error from summoner info request")
        return error_info
        
    try:
        url = ('https://na1.api.riotgames.com/lol/summoner/v4/summoners/by-puuid/' + puuid + '?api_key=' + key)
        response = requests.get(url)  # Fixed typo: reponse -> response
        summoner_info = response.json()
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred: {e}", exc_info=True)
        time.sleep(120)
        return summoner_level(puuid, key, retries-1)

    # Check for response errors
    try:
        # Check for rate limit errors or 500-504 server errors
        if summoner_info['status']['status_code'] >= 429:
            time.sleep(120)
            print("retrying summoner information request")
            return summoner_level(puuid, key, retries-1)
        
        # Check for client errors, or unauthorized requests
        if summoner_info['status']['status_code'] <= 415:
            error_info = {
                "summonerLevel": f"Error{summoner_info['status']['status_code']}",
                "revisionDate": f"Error{summoner_info['status']['status_code']}"
            }
            logging.error(f"Error {summoner_info['status']['status_code']}: {summoner_info['status']['message']} From url: {url}")
            print("client error from summoner info request")
            return error_info

    # KeyError because 'status' won't be in dictionary (successful response)
    except KeyError:
        return summoner_info
    
