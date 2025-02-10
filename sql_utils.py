import mysql.connector

def get_existing_columns(cursor, table_name):
    cursor.execute(f"DESCRIBE {table_name}")
    return [column[0] for column in cursor.fetchall()]

#helper function
def add_new_columns(cursor, table_name, new_columns, existing_columns, rows):
    for column in new_columns:
        if column not in existing_columns:
            value = search_rows(rows, column)
            datatype = infer_column_data_type(value)
            cursor.execute(f"ALTER TABLE {table_name} ADD COLUMN {column} {datatype}")
            print(f"Added new column: {column} datatype: {datatype}")

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


# Function to generate and execute CREATE TABLE statements
def create_tables_from_dict(tables_dict, cursor, conn):

    # Iterate through each table in the dictionary
    for table_name, rows in tables_dict.items():
        if rows:
            # Get the first row in the list to infer column names and types
            first_row = rows[0]
            
            column_definitions = []
            
            # For each key-value pair in the first row dictionary
            for column, value in first_row.items():
                # Infer the datatype of each column based on the value in the first row
                datatype = infer_column_data_type(value)

                # Add the column definition to the list
                column_definitions.append(f"{column} {datatype}")

            # Create the CREATE TABLE query
            create_table_query = f"CREATE TABLE IF NOT EXISTS {table_name} ({', '.join(column_definitions)});"

            # Execute the query to create the table
            try:
                cursor.execute(create_table_query)
                print(f"Table {table_name} created successfully.")
                conn.commit()
            except mysql.connector.Error as err:
                print(f"Error creating table {table_name}: {err}")
                conn.close()

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