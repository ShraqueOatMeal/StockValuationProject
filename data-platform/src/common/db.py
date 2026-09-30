import os
from pathlib import Path
from dotenv import load_dotenv
import psycopg2

# Load environment variables from data-platform/.env
env_path = Path(__file__).resolve().parent.parent.parent / '.env'
load_dotenv(dotenv_path=env_path)

def get_db_connection():
    """Returns a psycopg2 connection to PostgreSQL."""
    return psycopg2.connect(
        # 'localhost' for host execution, 'postgres' within docker network
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=int(os.getenv("POSTGRES_PORT", 5432)),
        dbname=os.getenv("POSTGRES_DB", "afive_dw"),
        user=os.getenv("POSTGRES_USER", "afive_admin"),
        password=os.getenv("POSTGRES_PASSWORD", "afive_secure_pass")
    )
