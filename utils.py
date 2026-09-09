#############################################################
# Util functions
#############################################################

from typing import TypedDict
import sqlalchemy
import json
import pandas as pd
import numpy as np
from pathlib import Path
from urllib.parse import quote_plus
import logging
import argparse
from dotenv import load_dotenv
import os

# set the logging level to INFO # This ensures that messages at or above the INFO level will be processed
logging.basicConfig(level=logging.INFO)
logger =  logging.getLogger(__name__)

# class for database configuration
class DatabaseConfig(TypedDict):
    user: str
    password: str
    host: str
    database: str


# loads the configuration from environment variables
def db_config(type:str=None) -> DatabaseConfig:
    load_dotenv()  # take environment variables from .env.
    prefix = "" if type is None else f"{type.upper()}_"

    config = DatabaseConfig(
        username=os.getenv(f"{prefix}DATABASE_USERNAME"),
        password=os.getenv(f"{prefix}DATABASE_PASSWORD"),
        host=os.getenv(f"{prefix}DATABASE_HOST"),
        database=os.getenv(f"{prefix}DATABASE_NAME")
    )    

    # basic validarion
    if not config['username'] or not config['password']:
        raise ValueError(
            f"Las credenciales de base de datos deben estar configuradas en las variables de entorno {prefix}DATABASE_USERNAME y {prefix}DATABASE_PASSWORD"
        )
    
    config['password'] = quote_plus(str(config['password'])) # URL-encode the password to handle special characters like '@'
    return config


# Engine class to handle database operations
class Engine:
    def __init__(self, config: DatabaseConfig = None, prod: bool = False):
        """
        Initializes the Engine with a database connection.
        Args:
            config (DatabaseConfig, optional): The database configuration. If None, uses default config.
            prod (bool, optional): Flag indicating if the environment is production. Defaults to False.
        """
        if config is None:              # ✅ fallback if no config passed
            config = db_config()
        self.engine = Engine._create_engine(config)
        self.prod = prod

    def execute(self, query: str) -> pd.DataFrame:
        df = pd.read_sql(query, self.engine)
        return df
    
    def close(self):
        self.engine.dispose()

    def upload_data(self, dataframe: pd.DataFrame, database: str, table_name: str):
        """
        Uploads a DataFrame into a SQL table.

        Args:
            dataframe (pd.DataFrame): The DataFrame to load.
            database (str): The name of the target database.
            table_name (str): The name of the target SQL table.
        """
        with self.engine.begin() as connection:
            try:
                table_exists = sqlalchemy.inspect(self.engine).has_table(table_name, schema=database)
                if table_exists:
                    connection.execute(sqlalchemy.text(f"DELETE FROM {database}.{table_name}"))
                # upload dataframe to table
                n = dataframe.to_sql(
                    name=table_name,
                    schema=database,
                    con=connection,
                    if_exists='append' if self.prod else 'replace',
                    index=False,
                    chunksize=10_000,       # split into 10k rows per insert
                    method='multi'        # sends multiple VALUES per INSERT
                )
                connection.commit()
                logger.info(f"Updated {n} rows in {database}.{table_name}")
            except sqlalchemy.exc.SQLAlchemyError as e:
                connection.rollback()
                logger.error(f"Error loading data into {database}.{table_name}: {e}")
                raise
            finally:
                connection.close()

    
    @classmethod
    def _create_engine(cls, config: DatabaseConfig) -> sqlalchemy.engine.base.Engine:
        # creates a SQLAlchemy engine using the provided database configuration
        username = config['username']
        password = config['password']
        host = config['host']
        database = config['database']

        engine = sqlalchemy.create_engine(
            f'mysql+mysqlconnector://{username}:{password}@{host}/{database}', 
            connect_args={"use_pure": True },
            pool_recycle=300, # recycle connections after 5 minutes
            pool_pre_ping=True, # check if connection is alive before using
        )

        return engine

def load_sql_query(filename: str, folder: str = "queries") -> str:
    """
    Loads the contents of an SQL file from the specified queries folder into a string.

    Args:
        filename (str): The name of the SQL file (e.g., "get_users.sql").
        folder (str, optional): The folder where SQL files are stored. Defaults to "queries".

    Returns:
        str: The SQL query as a string.

    Raises:
        FileNotFoundError: If the SQL file does not exist.
        IOError: If there is an error reading the file.
    """
    path = Path(folder) / filename
    if not path.is_file():
        raise FileNotFoundError(f"SQL file not found: {path}")

    return path.read_text(encoding="utf-8")