import mysql.connector
import datetime
import json

def get_existing_columns(cursor, table_name):
    cursor.execute(f"DESCRIBE {table_name}")
    return [column[0] for column in cursor.fetchall()]

#helper function
def add_new_columns(cursor, table_name, new_columns, existing_columns, rows):
    for column in new_columns:
        if column not in existing_columns:
            value = search_rows(rows, column)
            datatype = infer_column_data_type(value)
            try:
                cursor.execute(f"ALTER TABLE {table_name} ADD COLUMN {column} {datatype}")
                print(f"Added new column: {column} datatype: {datatype}")
            except mysql.connector.Error as e:
                print(e)

def align_row_data(row, existing_columns):
    return [row.get(col, None) for col in existing_columns]

def insert_data_to_mysql(cursor, table_name, rows):
    # Retrieve the current columns in the table (do this only once)
    existing_columns = get_existing_columns(cursor, table_name)

    # Get all unique columns from the rows and identify the missing columns
    new_columns = set(col for row in rows for col in row.keys())
    
    # Add missing columns to the table
    add_new_columns(cursor, table_name, new_columns, existing_columns, rows)
    
    # Align all rows with the existing columns (fill in None for missing columns)
    aligned_rows = [align_row_data(row, existing_columns) for row in rows]

    # Prepare the INSERT statement with placeholders for each column
    placeholders = ', '.join(['%s'] * len(existing_columns))
    sql = f"INSERT INTO {table_name} ({', '.join(existing_columns)}) VALUES ({placeholders})"

    # Use executemany to insert all rows at once
    cursor.executemany(sql, aligned_rows)
    print(f"Inserted {len(aligned_rows)} rows into {table_name}")

# Helper function to infer the datatype of a column based on the value
def infer_column_data_type(value):
    if isinstance(value, int):
        return "INT"
    elif isinstance(value, float):
        return "DECIMAL(10, 2)"
    elif isinstance(value, str):
        return "VARCHAR(255)"
    elif isinstance(value, bool):
        return "BOOLEAN"
    elif value is None:
        return "TEXT"  # For NULL values, TEXT can be used
    else:
        return "VARCHAR(255)"  # Default type for unknown types
    
def search_rows(rows, key):
    for dictionary in rows:
        if key in dictionary:
            return dictionary[key]

    return None

def ensure_healthy_connection(conn, cursor):
    try:
        conn.ping(reconnect=False)
        return conn, cursor
    except:
        logger.warning("⚠️ Connection unhealthy, reconnecting...")
        conn.reconnect()
        cursor = conn.cursor()
        return conn, cursor

def format_error_response(error, error_type, status_code, file_key=None, bucket=None, request_id=None, **kwargs):
    """Format consistent error response for Lambda functions"""
    error_response = {
        'error': str(error),
        'error_type': error_type,
        'status_code': status_code,
        'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat()
    }
    
    # Add file context if provided
    if file_key:
        error_response['file_key'] = file_key
    if bucket:
        error_response['bucket'] = bucket
    if request_id:
        error_response['request_id'] = request_id
    
    # Add any additional context
    if kwargs:
        error_response.update(kwargs)
    
    return {
        'statusCode': status_code,
        'body': json.dumps(error_response)
    }