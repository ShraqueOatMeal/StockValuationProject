import sys
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).resolve().parent.parent.parent))

import os
import json
import requests
from tenacity import retry, retry_if_exception, stop_after_attempt, wait_exponential
from src.common.db import get_db_connection

def _is_transient(exc: BaseException) -> bool:
    """Retry only on rate limiting, server errors and network failures (not on a bad CIK / 404)."""
    if isinstance(exc, requests.HTTPError):
        status = exc.response.status_code if exc.response is not None else None
        return status == 429 or (status is not None and status >= 500)
    return isinstance(exc, (requests.ConnectionError, requests.Timeout))

class SECClient:
    BASE_URL = "https://data.sec.gov"

    def __init__(self, user_agent: str = None):
        # SEC Fair Access requires: "App_Name contact_email"
        self.user_agent = user_agent or os.getenv("SEC_USER_AGENT", "AFIVE_Engine analyst@local.dev")
        self.headers = {"User-Agent": self.user_agent}

    # SEC limits traffic to 10 requests per second; back off and retry when throttled (429)
    @retry(
        retry=retry_if_exception(_is_transient),
        stop=stop_after_attempt(5),
        wait=wait_exponential(multiplier=1, min=2, max=10),
        reraise=True,
    )
    def _get_json(self, path: str) -> dict:
        response = requests.get(f"{self.BASE_URL}{path}", headers=self.headers, timeout=30)
        response.raise_for_status()
        return response.json()

    def fetch_company_facts(self, cik: str) -> dict:
        """
        Fetches full XBRL disclosure facts for a 10-digit padded CIK.
        Docs: https://www.sec.gov/edgar/sec-api-documentation
        """
        padded_cik = str(cik).zfill(10)
        return self._get_json(f"/api/xbrl/companyfacts/CIK{padded_cik}.json")

    def fetch_company_submissions(self, cik: str) -> dict:
        """
        Fetches entity metadata (SIC code, industry description, exchanges, fiscal year end).
        The companyfacts payload only carries cik / entityName / facts.
        """
        padded_cik = str(cik).zfill(10)
        return self._get_json(f"/submissions/CIK{padded_cik}.json")

def ingest_sec_filing(ticker: str, cik: str) -> bool:
    """
    Downloads all historical XBRL facts and entity metadata for a given ticker/CIK
    and stores the latest JSON payloads in bronze.raw_sec_filings.
    """
    print(f"Fetching SEC XBRL facts for {ticker} (CIK: {cik})...")
    client = SECClient()
    facts = client.fetch_company_facts(cik)
    submissions = client.fetch_company_submissions(cik)
    # Drop the bulky filing index; only the entity-level metadata is needed downstream
    submissions.pop("filings", None)

    # We store each payload under fiscal_year=0, fiscal_period='ALL' to maintain unique
    # constraint predictability for full-company historical dumps:
    #   form_type='FACTS'       -> XBRL company facts
    #   form_type='ENTITY' -> entity metadata (form_type is VARCHAR(10))
    insert_sql = """
    INSERT INTO bronze.raw_sec_filings (
        cik, ticker, form_type, fiscal_year, fiscal_period, payload
    ) VALUES (%s, %s, %s, %s, %s, %s)
    ON CONFLICT (cik, form_type, fiscal_year, fiscal_period)
    DO UPDATE SET
        ticker = EXCLUDED.ticker,
        payload = EXCLUDED.payload,
        ingested_at = CURRENT_TIMESTAMP;
    """

    padded_cik = str(cik).zfill(10)
    conn = get_db_connection()
    try:
        with conn.cursor() as cursor:
            for form_type, payload in (('FACTS', facts), ('ENTITY', submissions)):
                cursor.execute(insert_sql, (
                    padded_cik,
                    ticker.upper(),
                    form_type,
                    0,
                    'ALL',
                    json.dumps(payload)
                ))
        conn.commit()
    finally:
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
