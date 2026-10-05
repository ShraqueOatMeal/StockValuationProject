import sys
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).resolve().parent.parent.parent))

from datetime import date, timedelta

import yfinance as yf
from psycopg2.extras import execute_values
from src.common.db import get_db_connection

def fetch_and_store_market_data(ticker: str, period: str = "1mo", start: date = None) -> int:
    """
    Pulls OHLCV, splits, and dividend data from Yahoo Finance 
    and upserts into bronze.raw_market_prices.
    Fetches everything from `start` onwards when given, otherwise the trailing `period`.
    """
    stock = yf.Ticker(ticker)
    if start is not None:
        print(f"Fetching market data for: {ticker} (From: {start})")
        df = stock.history(start=start, auto_adjust=False)
    else:
        print(f"Fetching market data for: {ticker} (Period: {period})")
        df = stock.history(period=period, auto_adjust=False)

    # Yahoo returns NaN rows for halted / not-yet-settled sessions
    df = df.dropna(subset=['Open', 'High', 'Low', 'Close', 'Adj Close', 'Volume'])

    if df.empty:
        print(f"No records returned for {ticker}")
        return 0

    records = []
    for index, row in df.iterrows():
        trade_date = index.date()
        records.append((
            ticker.upper(),
            trade_date,
            float(row['Open']),
            float(row['High']),
            float(row['Low']),
            float(row['Close']),
            float(row['Adj Close']),
            int(row['Volume']),
            float(row.get('Dividends', 0.0)),
            # Yahoo reports 0.0 on days without a split; a neutral coefficient is 1.0
            float(row.get('Stock Splits', 0.0)) or 1.0
        ))

    # Update every price column on conflict: Yahoo restates OHLC after splits, and a row
    # first captured mid-session must be overwritten by the final end-of-day bar.
    insert_sql = """
    INSERT INTO bronze.raw_market_prices (
        ticker, trade_date, open_price, high_price, low_price,
        close_price, adj_close, volume, dividend_amount, split_coefficient
    ) VALUES %s
    ON CONFLICT (ticker, trade_date)
    DO UPDATE SET
        open_price = EXCLUDED.open_price,
        high_price = EXCLUDED.high_price,
        low_price = EXCLUDED.low_price,
        close_price = EXCLUDED.close_price,
        adj_close = EXCLUDED.adj_close,
        volume = EXCLUDED.volume,
        dividend_amount = EXCLUDED.dividend_amount,
        split_coefficient = EXCLUDED.split_coefficient,
        ingested_at = CURRENT_TIMESTAMP;
    """

    conn = get_db_connection()
    try:
        with conn.cursor() as cursor:
            execute_values(cursor, insert_sql, records)
        conn.commit()
    finally:
        conn.close()

    row_count = len(records)
    print(f"Successfully upserted {row_count} rows for {ticker}")
    return row_count

def fetch_and_store_incremental(ticker: str, backfill_period: str = "1y", lookback_days: int = 7) -> int:
    """
    Loads only what is missing: everything since the last stored trade date, plus a few
    days of overlap so late corrections from Yahoo are picked up. A ticker with no
    history yet gets the full backfill period, and a gap left by an outage is filled
    automatically because the window always starts from the last stored date.
    """
    conn = get_db_connection()
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                "SELECT max(trade_date) FROM bronze.raw_market_prices WHERE ticker = %s;",
                (ticker.upper(),)
            )
            last_trade_date = cursor.fetchone()[0]
    finally:
        conn.close()

    if last_trade_date is None:
        return fetch_and_store_market_data(ticker, period=backfill_period)

    return fetch_and_store_market_data(ticker, start=last_trade_date - timedelta(days=lookback_days))

if __name__ == "__main__":
    # Test locally on a Bursa Malaysia ticker and a US equity
    test_tickers = ["1155.KL", "GOOGL"]
    for t in test_tickers:
        fetch_and_store_market_data(t, period="1mo")
