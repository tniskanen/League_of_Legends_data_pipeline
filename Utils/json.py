from collections import deque

def flatten_json(nested_json):
    """Flatten the JSON into a single level (row)."""
    out = {}  # This will hold the flattened result
    queue = deque([((), nested_json)])  # Initialize a queue with the root of the JSON structure

    while queue:  # Loop through the queue until it's empty
        path, current = queue.popleft()  # Get the current path and data from the queue

        # If the current element is a dictionary:
        if isinstance(current, dict):
            for key, value in current.items():
                new_path = path + (key,)  # Create a new path by appending the current key
                queue.append((new_path, value))  # Add the new path and value to the queue

        # If the current element is a list:
        elif isinstance(current, list):
            for idx, item in enumerate(current):  # Iterate through each item in the list
                new_path = path + (str(idx),)  # Create a new path by appending the index
                queue.append((new_path, item))  # Add the new path and item to the queue

        # If the current element is a value (neither dict nor list):
        else:

            #not including legendaryItemUsed 
            path_str = "_".join(path)
            if any(keyword in path_str for keyword in ['legendaryItemUsed', 'SWARM', 'playerAugment', 'PlayerScore']):
                continue
            else:
                out[path_str] = current  # Use the path_str we already created

    return out  # Return the flattened dictionary

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
    
    
    return (flatten_json(out))

def flatten_participant_frames(frame):
    
    championStats = frame['championStats'].copy()
    frame.pop('championStats')
    frame.update(championStats)

    damageStats = frame['damageStats'].copy()
    frame.pop('damageStats')
    frame.update(damageStats)

    position = flatten_json(frame['position'])
    frame.pop('position')
    frame.update(position)

    return frame

def split_json(flat_dict):
    legendaryItems = {}
    challenges = {}
    perkMissionStats = {}
    basicStats = {}
    
    for key, value in flat_dict.items():
        if key.startswith('perks') or key.startswith('missions'):
            perkMissionStats[key] = value
        elif key.startswith('challenges'):
            if key.startswith('challenges_legendaryItemUsed'):
                legendaryItems[key] = value
            else:
                challenges[key] = value
        else:
            basicStats[key] = value

    dicts = [basicStats, challenges, legendaryItems, perkMissionStats]
    
    return dicts

def add_join_keys(dicts):

    #add keys for joins
    for i in range(1, 4):
        dicts[i]['matchId'] = dicts[0]['matchId']
        dicts[i]['championName'] = dicts[0]['championName']

    return dicts

