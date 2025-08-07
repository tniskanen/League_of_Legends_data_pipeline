from Utils.api import matchList, highElo, handle_api_response

key = 'RGAPI-0dc7e440-7365-44ff-bf2d-8d4057782e52'
start_epoch = 1717737600
end_epoch = 1723008000


def run_fetcher():

    low_elo_players = []
    high_elo_players = []
    matchesList = []
    ranks = ['master']  
   

    try:
        print("Fetching high elo players...")
        for rank in ranks:
            print(f"  Fetching {rank} players...")
            json_response = highElo(rank, key)
            if json_response and 'entries' in json_response:
                high_elo_players.extend(json_response['entries'])
                print(f"    Added {len(json_response['entries'])} {rank} players (total: {len(high_elo_players)})")
                if (len(low_elo_players) + len(high_elo_players)) >= 100:
                    print(f"    Reached player limit at {rank}")
                    break
            else:
                print(f"No entries found for rank: {rank}")
    except Exception as e:
        print(f"🛑 High elo player collection failed - incomplete data would be catastrophic")
        print(f"📋 Manual intervention required: Check API key and Riot API status")

    print(f"Player collection complete: High={len(high_elo_players)}, Low={len(low_elo_players)}, Total={len(high_elo_players) + len(low_elo_players)}")

    # Build a dictionary mapping puuid -> rank data
    normalized_high_elo = []

    for player in high_elo_players:
        normalized_high_elo.append({
            'puuid': player['puuid'],
            'tier': None, 
            'rank': None, 
            'lp': player.get('leaguePoints', 0)
        })

    normalized_low_elo = []

    for player in low_elo_players:
        normalized_low_elo.append({
            'puuid': player['puuid'],
            'tier': player['tier'].upper(),  # e.g., "DIAMOND", "PLATINUM"
            'rank': player.get('rank', None),  # e.g., "I", "II", "III", "IV"
            'lp': player.get('leaguePoints', 0)
        })

    # Limit player list to the environment-defined max (e.g., 100 for test, 100000 for prod)
    ranked_players = normalized_high_elo + normalized_low_elo

    player_rank_map = {
        player['puuid']: {
            'tier': player['tier'],
            'rank': player['rank'],
            'lp': player['lp']
        }
        for player in ranked_players if 'puuid' in player
    }

    ranked_players = ranked_players[:100]
    print(f"Created rank mapping for {len(player_rank_map)} players")
    print("Fetching match lists...")

    try:
        match_count = 0
        for i, player in enumerate(ranked_players):
            puuid = player.get('puuid')
            if not puuid:
                print(f"No puuid found for player {i}")
                continue
                
            # Progress indicator every 1000 players
            if i % 1000 == 0 and i != 0:
                print(f"  Progress: {i}/{len(ranked_players)} players processed, {match_count} matches found")
                
            tempMatches = matchList(player['puuid'], key, start_epoch, end_epoch)
            print(tempMatches)
            if isinstance(tempMatches, list):
                matchesList.extend(tempMatches)
                match_count += len(tempMatches)
            else:
                handle_api_response(tempMatches, func_name='matchList', player_id=player['puuid'])
    except Exception as e:
        print(f"❌ CRITICAL ERROR during matchList request: {e}")
        print(f"🛑 Matchlist generation failed at player {i}/{len(ranked_players)}")
        print(f"📋 Incomplete matchlist would be useless - backfill required")
        print(f"📋 Manual intervention required: Check API key and Riot API status")

    uniqueMatches = set(matchesList)
    print(f"Found {len(uniqueMatches)} unique matches to process")

if __name__ == "__main__":
    run_fetcher()
   
    

