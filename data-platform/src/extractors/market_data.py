import sys
from pathlib import Path

# Add project root to sys.path
sys.path.append(str(Path(__file__).resolve().parent.parent.parent))

import yfinance as yf
from psycopg2.extras import execute_values
from src.common.db import get_db_connection

def fetch_and_store_market_data(ticker: str, period: str = "1mo") -> int:
    """
    Pulls OHLCV, splits, and dividend data from Yahoo Finance 
    and upserts into bronze.raw_market_prices.
    """
    print(f"Fetching market data for: {ticker} (Period: {period})")
    stock = yf.Ticker(ticker)
    df = stock.history(period=period, auto_adjust=False)

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
            float(row.get('Stock Splits', 1.0))
        ))

    insert_sql = """
    INSERT INTO bronze.raw_market_prices (
        ticker, trade_date, open_price, high_price, low_price,
        close_price, adj_close, volume, dividend_amount, split_coefficient
    ) VALUES %s
    ON CONFLICT (ticker, trade_date)
    DO UPDATE SET
        adj_close = EXCLUDED.adj_close,
        volume = EXCLUDED.volume,
        dividend_amount = EXCLUDED.dividend_amount,
        split_coefficient = EXCLUDED.split_coefficient,
        ingested_at = CURRENT_TIMESTAMP;
    """

    conn = get_db_connection()
    cursor = conn.cursor()
    execute_values(cursor, insert_sql, records)
    conn.commit()
    
    row_count = len(records)
    cursor.close()
    conn.close()
    
    print(f"Successfully upserted {row_count} rows for {ticker}")
    return row_count

if __name__ == "__main__":
    # Test locally on a Bursa Malaysia ticker and a US equity
    test_tickers = ["1155.KL", "GOOGL"]
    for t in test_tickers:
        fetch_and_store_market_data(t, period="1mo")
