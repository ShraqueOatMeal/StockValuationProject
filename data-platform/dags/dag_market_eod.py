import sys
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator

# Ensure Airflow detects local modules
sys.path.append('/opt/airflow')

from src.extractors.market_data import fetch_and_store_market_data
from src.extractors.fundamentals import fetch_and_store_fundamentals
from src.extractors.sec_edgar import ingest_sec_filing

default_args = {
    'owner': 'afive',
    'depends_on_past': False,
    'start_date': datetime(2026, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=3),
}

# Core asset universe (US Equities + Bursa Malaysia)
WATCHLIST = [
    {"ticker": "1155.KL", "cik": None},          # Malayan Banking Bhd
    {"ticker": "GOOGL", "cik": "0001652044"},    # Alphabet Inc.
    {"ticker": "NOW", "cik": "0001373715"},      # ServiceNow Inc.
]

with DAG(
    'dag_market_eod',
    default_args=default_args,
    description='Automated EOD market data ingestion and SEC XBRL sync into Bronze',
    schedule_interval='0 22 * * 1-5',  # Mon-Fri at 22:00 UTC (Post Market Close)
    catchup=False,
    max_active_runs=1,
    tags=['bronze', 'ingestion', 'eod'],
) as dag:

    def run_market_data(ticker: str):
        count = fetch_and_store_market_data(ticker, period="5d")
        print(f"Recorded {count} rows for {ticker}")

    def run_fundamentals(ticker: str):
        count = fetch_and_store_fundamentals(ticker)
        print(f"Recorded {count} statements for {ticker}")

    def run_sec_edgar(ticker: str, cik: str):
        if cik:
            ingest_sec_filing(ticker, cik)
            print(f"Refreshed SEC XBRL disclosure for {ticker}")

    for item in WATCHLIST:
        ticker = item["ticker"]
        cik = item["cik"]
        safe_id = ticker.replace('.', '_')

        # Task 1: Ingest price, volume, and cash dividends
        price_task = PythonOperator(
            task_id=f"ingest_prices_{safe_id}",
            python_callable=run_market_data,
            op_kwargs={"ticker": ticker},
        )

        # Task 2: Ingest Yahoo Finance fundamentals (the only source for non-SEC filers)
        fundamentals_task = PythonOperator(
            task_id=f"ingest_fundamentals_{safe_id}",
            python_callable=run_fundamentals,
            op_kwargs={"ticker": ticker},
        )
        price_task >> fundamentals_task

        # Task 3: Ingest SEC filings if CIK is present
        if cik:
            sec_task = PythonOperator(
                task_id=f"ingest_sec_{safe_id}",
                python_callable=run_sec_edgar,
                op_kwargs={"ticker": ticker, "cik": cik},
            )
            # Market prices run first, followed by filings extraction
            price_task >> sec_task
