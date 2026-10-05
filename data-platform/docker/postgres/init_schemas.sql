-- 1. Create Medallion and Application Schemas
CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;
CREATE SCHEMA IF NOT EXISTS app_state;

-- 2. SEC EDGAR Raw Filings Table (Stores raw XBRL JSON payloads)
CREATE TABLE IF NOT EXISTS bronze.raw_sec_filings (
    id BIGSERIAL PRIMARY KEY,
    cik VARCHAR(10) NOT NULL,
    ticker VARCHAR(12) NOT NULL,
    form_type VARCHAR(10) NOT NULL, -- e.g., '10-K', '10-Q', or 'ALL_FACTS'
    fiscal_year INT,
    fiscal_period VARCHAR(10),       -- 'FY', 'Q1', 'Q2', 'Q3'
    payload JSONB NOT NULL,
    ingested_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_sec_filing UNIQUE (cik, form_type, fiscal_year, fiscal_period)
);

CREATE INDEX IF NOT EXISTS idx_raw_sec_ticker ON bronze.raw_sec_filings(ticker);

-- 3. Daily Market Prices & Distribution History
CREATE TABLE IF NOT EXISTS bronze.raw_market_prices (
    id BIGSERIAL PRIMARY KEY,
    ticker VARCHAR(20) NOT NULL,
    trade_date DATE NOT NULL,
    open_price NUMERIC(14, 4),
    high_price NUMERIC(14, 4),
    low_price NUMERIC(14, 4),
    close_price NUMERIC(14, 4),
    adj_close NUMERIC(14, 4) NOT NULL,
    volume BIGINT,
    dividend_amount NUMERIC(10, 4) DEFAULT 0.0,
    split_coefficient NUMERIC(10, 4) DEFAULT 1.0,
    ingested_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_market_price_date UNIQUE (ticker, trade_date)
);

CREATE INDEX IF NOT EXISTS idx_raw_price_lookup ON bronze.raw_market_prices(ticker, trade_date DESC);

-- 4. Macroeconomic Benchmark Yields (Risk-Free Rates for WACC/DCF)
CREATE TABLE IF NOT EXISTS bronze.raw_macro_yields (
    id BIGSERIAL PRIMARY KEY,
    series_id VARCHAR(50) NOT NULL, -- e.g., 'US_10Y_TREASURY' or 'MGS_10Y_BENCHMARK'
    observation_date DATE NOT NULL,
    yield_percent NUMERIC(6, 4) NOT NULL,
    ingested_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_macro_yield UNIQUE (series_id, observation_date)
);

-- 5. Yahoo Finance Fundamentals (fallback for non-SEC filers and for line items missing from XBRL)
CREATE TABLE IF NOT EXISTS bronze.raw_yf_fundamentals (
    id BIGSERIAL PRIMARY KEY,
    ticker VARCHAR(20) NOT NULL,
    statement_type VARCHAR(10) NOT NULL, -- 'income', 'balance', 'cashflow'
    frequency VARCHAR(10) NOT NULL,      -- 'quarterly', 'annual'
    payload JSONB NOT NULL,              -- { "<period end date>": { "<line item>": value, ... }, ... }
    ingested_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_yf_fundamentals UNIQUE (ticker, statement_type, frequency)
);
