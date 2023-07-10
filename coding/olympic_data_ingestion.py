import json, gzip, os
from sqlalchemy import create_engine, MetaData, Table, Column, Integer, String, select, cast, JSON, inspect, func, text

# Step 1: READ the JSONL file
json_file_path = './raw_data/athlete_events_2006_2016.jsonl.gz'
with gzip.open(json_file_path, 'rt') as file:
    json_data = file.readlines()

# Step 2: Parse the JSONL data
parsed_data = [json.loads(line) for line in json_data]

# Step 4: Connect to the PostgreSQL database
host = os.environ.get('pghost')
port = os.environ.get('pgport')
database = os.environ.get('pgdatabase')
user = os.environ.get('pguser')
password = os.environ.get('pgpassword')

connection_params = {
    'host': host,
    'port': port,
    'database': database,
    'user': user,
    'password': password
}

# Create the connection string
connection_string = "postgresql+psycopg2://{user}:{password}@{host}:{port}/{database}".format(
    user=user, password=password, host=host, port=port, database=database
)
engine = create_engine(connection_string)

# Step 5: Import/Copy the transformed data into the database
metadata = MetaData()
metadata.reflect(bind=engine)
inspector = inspect(engine)

# Step 6: Create the table schema for raw_data.olympics
raw_data_schema = 'raw_data'
raw_table_name = 'olympics'

# Step 7: Create the table if it doesn't exist
raw_table = Table(
    raw_table_name,
    metadata,
    Column('data', JSON),
    schema=raw_data_schema
)
if not inspector.has_table(raw_table_name, schema=raw_data_schema):
    raw_table.create(bind=engine, checkfirst=True)

# Step 8: Insert the transformed data into the table
with engine.begin() as connection:
    connection.execute(raw_table.insert(), [{"data": row} for row in parsed_data])

# Step 9: Perform any additional optimizations (e.g., creating cluster partitions)

# Step 10: Create the processed_data_table
output_data_schema = 'olympics'
output_table_name = 'medal_awards'

# Extract unique keys from the JSON data
keys = set()
numeric_columns = ['age', 'weight', 'athlete_id', 'height', 'year']

for item in parsed_data:
    keys.update(item.keys())

# Define the table dynamically based on the unique keys
processed_table_columns = [
    Column(key, Integer) if key in numeric_columns else Column(key, String)
    for key in keys
]

processed_table = Table(
    output_table_name,
    metadata,
    *processed_table_columns,
    schema=output_data_schema,
    extend_existing=True  # Enable extending the existing table
)

# Step 11: Create the table if it doesn't exist
if not inspector.has_table(output_table_name, schema=output_data_schema):
    processed_table.create(bind=engine, checkfirst=True)

# Step 12: Populate the processed_data_table
insert_query = processed_table.insert().from_select(
    processed_table.columns.keys(),
    select(*[cast(func.json_extract_path_text(raw_table.c.data, key), Integer).label(key) if key in numeric_columns else cast(func.json_extract_path_text(raw_table.c.data, key), String).label(key) for key in keys])
    .select_from(raw_table)
)

with engine.begin() as connection:
    connection.execute(insert_query)

# Step 13: Create the medal_summary table
reporting_data_schema = 'reporting'
medal_summary_table_name = 'medal_summary'
medal_summary_table = Table(
    medal_summary_table_name,
    metadata,
    Column('year', Integer),
    Column('season', String),
    Column('countries_with_medals', Integer),
    schema=reporting_data_schema,
    extend_existing=True
)

# Step 14: Create the table if it doesn't exist
if not inspector.has_table(medal_summary_table_name, schema=reporting_data_schema):
    medal_summary_table.create(bind=engine, checkfirst=True)

# Step 15: Populate the medal_summary table
insert_query = medal_summary_table.insert().from_select(
    ['year', 'season', 'countries_with_medals'],
    select(
        cast(processed_table.c.year, Integer),
        processed_table.c.season,
        func.count(func.distinct(processed_table.c.team)).label('countries_with_medals')
    )
    .select_from(processed_table)
    .where(processed_table.c.medal.isnot(None))
    .group_by(processed_table.c.year, processed_table.c.season)
)

with engine.begin() as connection:
    connection.execute(insert_query)

# Close the database connection (if necessary)
engine.dispose()
