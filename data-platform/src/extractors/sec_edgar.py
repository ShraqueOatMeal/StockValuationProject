import sys
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).resolve().parent.parent.parent))

import os
import json
import time
import requests
from tenacity import retry, stop_after_attempt, wait_exponential
from src.common.db import get_db_connection

class SECClient:
    BASE_URL = "https://data.sec.gov/api/xbrl/companyfacts"

    def __init__(self, user_agent: str = None):
        # SEC Fair Access requires: "App_Name contact_email"
        self.user_agent = user_agent or os.getenv("SEC_USER_AGENT", "AFIVE_Engine analyst@local.dev")
        self.headers = {"User-Agent": self.user_agent}

    @retry(stop=stop_after_attempt(5), wait=wait_exponential(multiplier=1, min=2, max=10))
    def fetch_company_facts(self, cik: str) -> dict:
        """
        Fetches full XBRL disclosure facts for a 10-digit padded CIK.
        Docs: https://www.sec.gov/edgar/sec-api-documentation
        """
        padded_cik = str(cik).zfill(10)
        url = f"{self.BASE_URL}/CIK{padded_cik}.json"

        response = requests.get(url, headers=self.headers, timeout=15)

        # SEC limits traffic to 10 requests per second
        if response.status_code == 429:
            time.sleep(2)
            response.raise_for_status()

        response.raise_for_status()
        return response.json()

def ingest_sec_filing(ticker: str, cik: str) -> bool:
    """
    Downloads all historical XBRL facts for a given ticker/CIK
    and stores the immutable JSON payload in bronze.raw_sec_filings.
    """
    print(f"Fetching SEC XBRL facts for {ticker} (CIK: {cik})...")
    client = SECClient()
    facts = client.fetch_company_facts(cik)

    conn = get_db_connection()
    cursor = conn.cursor()

    # We store the entire payload under form_type='FACTS', fiscal_year=0, fiscal_period='ALL'
    # to maintain unique constraint predictability for full-company historical dumps
    insert_sql = """
    INSERT INTO bronze.raw_sec_filings (
        cik, ticker, form_type, fiscal_year, fiscal_period, payload
    ) VALUES (%s, %s, %s, %s, %s, %s)
    ON CONFLICT (cik, form_type, fiscal_year, fiscal_period)
    DO UPDATE SET
        payload = EXCLUDED.payload,
        ingested_at = CURRENT_TIMESTAMP;
    """

    padded_cik = str(cik).zfill(10)
    cursor.execute(insert_sql, (
        padded_cik,
        ticker.upper(),
        'FACTS',
        0,
        'ALL',
        json.dumps(facts)
    ))

    conn.commit()
    cursor.close()
    conn.close()
    print(f"Successfully landed SEC facts payload for {ticker}")
    return True

if __name__ == "__main__":
    # Test on US tech holdings
    # CIKs: Alphabet (0001652044), ServiceNow (0001373715)
    test_cases = [
        {"ticker": "GOOGL", "cik": "0001652044"},
        {"ticker": "NOW", "cik": "0001373715"}
    ]
    for case in test_cases:
        ingest_sec_filing(case["ticker"], case["cik"])
