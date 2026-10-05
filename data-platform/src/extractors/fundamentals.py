import sys
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).resolve().parent.parent.parent))

import json
import pandas as pd
import yfinance as yf
from src.common.db import get_db_connection

def _statement_to_payload(df: pd.DataFrame, existing: dict) -> dict:
    """
    Converts a Yahoo Finance statement (line items as rows, period ends as columns)
    into { "<period end date>": { "<line item>": value } }, dropping empty cells.
    Periods already stored are kept, because Yahoo only serves the latest few periods.
    """
    payload = dict(existing)
    for period_end, column in df.items():
        values = {item: float(value) for item, value in column.dropna().items()}
        if values:
            payload[period_end.strftime("%Y-%m-%d")] = values
    return payload

def fetch_and_store_fundamentals(ticker: str) -> int:
    """
    Pulls quarterly and annual income statement, balance sheet and cash flow data
    from Yahoo Finance and upserts into bronze.raw_yf_fundamentals.
    """
    print(f"Fetching fundamentals for: {ticker}")
    stock = yf.Ticker(ticker)
    statements = {
        ('income', 'quarterly'): stock.quarterly_income_stmt,
        ('balance', 'quarterly'): stock.quarterly_balance_sheet,
        ('cashflow', 'quarterly'): stock.quarterly_cashflow,
        ('income', 'annual'): stock.income_stmt,
        ('balance', 'annual'): stock.balance_sheet,
        ('cashflow', 'annual'): stock.cashflow,
    }

    select_sql = """
    SELECT payload FROM bronze.raw_yf_fundamentals
    WHERE ticker = %s AND statement_type = %s AND frequency = %s;
    """
    insert_sql = """
    INSERT INTO bronze.raw_yf_fundamentals (ticker, statement_type, frequency, payload)
    VALUES (%s, %s, %s, %s)
    ON CONFLICT (ticker, statement_type, frequency)
    DO UPDATE SET
        payload = EXCLUDED.payload,
        ingested_at = CURRENT_TIMESTAMP;
    """

    stored = 0
    conn = get_db_connection()
    try:
        with conn.cursor() as cursor:
            for (statement_type, frequency), df in statements.items():
                if df is None or df.empty:
                    print(f"No {frequency} {statement_type} statement returned for {ticker}")
                    continue

                cursor.execute(select_sql, (ticker.upper(), statement_type, frequency))
                row = cursor.fetchone()
                payload = _statement_to_payload(df, row[0] if row else {})
                if not payload:
                    continue

                cursor.execute(insert_sql, (ticker.upper(), statement_type, frequency, json.dumps(payload)))
                stored += 1
        conn.commit()
    finally:
        conn.close()

    print(f"Successfully upserted {stored} statements for {ticker}")
    return stored

if __name__ == "__main__":
    # Test locally on a Bursa Malaysia ticker and a US equity
    test_tickers = ["1155.KL", "GOOGL"]
    for t in test_tickers:
        fetch_and_store_fundamentals(t)
