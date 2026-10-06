import sys
from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

# Ensure Airflow detects local modules
sys.path.append('/opt/airflow')

from src.extractors.market_data import fetch_and_store_incremental, fetch_and_store_market_data
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

# Price history loaded for a new ticker and re-pulled by the weekly full refresh. One year
# covers the 50-day moving average and a year of daily valuations; nothing reads further back.
PRICE_BACKFILL_PERIOD = "1y"
# Days re-fetched before the last stored trade date on each daily run, so corrections
# Yahoo makes to recent bars are picked up
PRICE_LOOKBACK_DAYS = 7

# dbt runs from its own virtual environment (see Dockerfile). Build artefacts go to /tmp
# because the project directory is a bind mount owned by the host user.
# Source freshness runs first: if a load silently wrote nothing and the raw data is older
# than the limits in sources.yml, the task fails before any model is rebuilt on stale data.
DBT_COMMAND = (
    "cd /opt/airflow/dbt_afive && "
    "/opt/airflow/dbt_venv/bin/dbt source freshness --profiles-dir . && "
    "/opt/airflow/dbt_venv/bin/dbt build --profiles-dir . {flags}"
)
DBT_ENV = {
    "DBT_TARGET_PATH": "/tmp/dbt_target",
    "DBT_LOG_PATH": "/tmp/dbt_logs",
}

def dbt_task(task_id: str, flags: str = "") -> BashOperator:
    return BashOperator(
        task_id=task_id,
        bash_command=DBT_COMMAND.format(flags=flags),
        env=DBT_ENV,
        append_env=True,
        # A failed model or test is a code or data problem; retrying it rarely helps
        retries=1,
    )

with DAG(
    'dag_market_eod',
    default_args=default_args,
    description='Automated EOD market data ingestion, SEC XBRL sync and incremental dbt refresh',
    schedule_interval='0 22 * * 1-5',  # Mon-Fri at 22:00 UTC (Post Market Close)
    catchup=False,
    max_active_runs=1,
    tags=['bronze', 'ingestion', 'eod', 'dbt'],
) as dag:

    def run_market_data(ticker: str):
        count = fetch_and_store_incremental(
            ticker,
            backfill_period=PRICE_BACKFILL_PERIOD,
            lookback_days=PRICE_LOOKBACK_DAYS,
        )
        print(f"Recorded {count} rows for {ticker}")

    def run_fundamentals(ticker: str):
        count = fetch_and_store_fundamentals(ticker)
        print(f"Recorded {count} statements for {ticker}")

    def run_sec_edgar(ticker: str, cik: str):
        if cik:
            ingest_sec_filing(ticker, cik)
            print(f"Refreshed SEC XBRL disclosure for {ticker}")

    # Final task: incremental dbt refresh (models + tests) once every ingestion task succeeds.
    # Price models only reprocess newly ingested dates; the small financial models rebuild.
    dbt_refresh = dbt_task("dbt_incremental_refresh")

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
        price_task >> fundamentals_task >> dbt_refresh

        # Task 3: Ingest SEC filings if CIK is present
        if cik:
            sec_task = PythonOperator(
                task_id=f"ingest_sec_{safe_id}",
                python_callable=run_sec_edgar,
                op_kwargs={"ticker": ticker, "cik": cik},
            )
            # Market prices run first, followed by filings extraction
            price_task >> sec_task >> dbt_refresh

with DAG(
    'dag_weekly_full_refresh',
    default_args=default_args,
    description='Weekly re-pull of price history and full dbt rebuild',
    schedule_interval='0 3 * * 0',  # Sunday at 03:00 UTC (markets closed)
    catchup=False,
    max_active_runs=1,
    tags=['bronze', 'ingestion', 'weekly', 'dbt'],
) as weekly_dag:

    def run_price_backfill(ticker: str):
        # Yahoo restates adjusted closes after dividends and splits, so the whole
        # backfill window is re-pulled rather than only the recent days
        count = fetch_and_store_market_data(ticker, period=PRICE_BACKFILL_PERIOD)
        print(f"Recorded {count} rows for {ticker}")

    # Full rebuild of every model: picks up restated financials, changed dbt vars and
    # new columns, none of which the daily incremental run goes back for
    dbt_full_refresh = dbt_task("dbt_full_refresh", flags="--full-refresh")

    for item in WATCHLIST:
        ticker = item["ticker"]
        safe_id = ticker.replace('.', '_')

        PythonOperator(
            task_id=f"backfill_prices_{safe_id}",
            python_callable=run_price_backfill,
            op_kwargs={"ticker": ticker},
        ) >> dbt_full_refresh
