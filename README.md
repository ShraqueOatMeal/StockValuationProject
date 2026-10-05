# Stock Valuation Project (AFIVE)

A stock valuation workbench in two parts:

- **`data-platform/`** — a medallion-style data warehouse on PostgreSQL. Airflow ingests daily prices from Yahoo Finance and XBRL financial statements from SEC EDGAR; dbt turns them into quarterly financials and daily valuation multiples.
- **`stockValuation/`** — a Laravel + Inertia + React app that reads the warehouse and provides a valuation dashboard, per-company financial statements, peer comparison and an interactive DCF model with saved scenarios.

The watchlist currently covers Alphabet (`GOOGL`), ServiceNow (`NOW`) and Malayan Banking (`1155.KL`). Fundamentals are only available for SEC filers, so the Bursa Malaysia ticker has prices but no financial statements.

## Architecture

```
Yahoo Finance ──┐                                             ┌── Dashboard
                ├─► bronze ──► staging ──► silver ──► gold ──►│   Company page (statements, peers, DCF)
SEC EDGAR ──────┘   (raw)      (views)     (tables)  (marts)  └── Saved DCF scenarios
   Airflow DAG          └────────── dbt ──────────┘               Laravel + React
```

Everything lives in one PostgreSQL database (`afive_dw`). The warehouse owns the `bronze`, `silver` and `gold` schemas; the Laravel app keeps its own tables (users, sessions, `user_dcf_scenarios`) in `public` and reads `gold` as read-only models.

## Repository layout

```
data-platform/
  dags/dag_market_eod.py        Airflow DAG: daily price + SEC ingestion (Mon–Fri 22:00 UTC)
  src/extractors/               market_data.py (Yahoo Finance), sec_edgar.py (SEC EDGAR)
  src/common/db.py              PostgreSQL connection helper
  dbt_afive/                    dbt project (staging / silver / gold models)
  docker/postgres/              Schema and bronze table DDL, run on first database start
  docker-compose.yml            PostgreSQL, Redis, Airflow webserver + scheduler
stockValuation/
  app/Http/Controllers/         ValuationDashboardController, CompanyValuationController
  app/Models/                   Company, QuarterlyFinancial, DailyMarketValuation, UserDcfScenario
  app/Services/Valuation/       DCF calculator
  resources/js/pages/           Dashboard.tsx, companies/show.tsx
```

## Data model

| Layer | Object | What it holds |
| --- | --- | --- |
| bronze | `raw_market_prices` | Daily OHLCV, adjusted close, dividends and splits per ticker |
| bronze | `raw_sec_filings` | One JSONB row per company and payload type: `FACTS` (XBRL company facts) and `ENTITY` (SIC code, industry, exchanges) |
| staging | `stg_market_prices`, `stg_sec_facts` | Typed views over bronze; `stg_sec_facts` unnests the selected XBRL tags into one row per reported fact |
| silver | `silver_market_prices` | Prices with daily return, dollar volume and 20/50-day moving averages |
| silver | `silver_financial_statements_scd2` | Every filed version of each fact, with `valid_from` / `valid_to` / `is_current` so restatements are tracked |
| gold | `dim_company` | Ticker, name, currency, exchange and industry |
| gold | `fact_quarterly_financials` | One row per company and quarter: income statement, balance sheet and cash flow items, margins, TTM sums and YoY growth |
| gold | `fact_daily_market_valuation` | Daily price joined to the latest financials filed on or before that date: market cap, enterprise value, P/E, P/FCF, EV/Sales, EV/EBIT |
| gold | `agg_industry_benchmarks` | Median multiples per industry |

Notes on `fact_quarterly_financials`:

- Quarterly flows are the directly reported three-month figure where one exists, otherwise year-to-date minus the previous year-to-date. This is how Q4 and cash flow items are derived, since 10-Ks report only the full year and 10-Qs report cash flows year-to-date.
- `fiscal_year` and `fiscal_period` are the calendar year and quarter of the period end date.
- `filing_date` is the first filing that reported the period, which keeps the join in `fact_daily_market_valuation` point-in-time.
- Margins and `fcf_conversion` are stored as ratios (0.6165 = 61.65%); the Laravel controllers convert them to percentages for display.

## Getting started

### Prerequisites

- Docker and Docker Compose
- [uv](https://docs.astral.sh/uv/) and Python 3.14+ (for running dbt and the extractors from the host)
- PHP 8.3+, Composer and Node.js

### 1. Start the data platform

```bash
cd data-platform
```

Create `data-platform/.env`:

```dotenv
POSTGRES_USER=afive_admin
POSTGRES_PASSWORD=<choose a password>
POSTGRES_DB=afive_dw
POSTGRES_PORT=5432
REDIS_PORT=6379
AIRFLOW_UID=50000
SEC_USER_AGENT=YourAppName you@example.com
```

`SEC_USER_AGENT` must identify you with a real contact email; SEC EDGAR rejects anonymous traffic.

```bash
docker compose up -d
```

This starts PostgreSQL on port 5432 (creating the schemas and bronze tables on first run), Redis, and Airflow at <http://localhost:8080> (login `admin` / `admin`).

### 2. Ingest data

Either unpause `dag_market_eod` in the Airflow UI, or run the extractors directly from the host:

```bash
uv sync
uv run python src/extractors/sec_edgar.py     # XBRL facts + entity metadata
uv run python src/extractors/market_data.py   # last month of prices
```

The DAG fetches the last five trading days on each run, so use the script (or call `fetch_and_store_market_data(ticker, period="5y")`) to load price history for a new ticker.

To add a company, append it to `WATCHLIST` in `dags/dag_market_eod.py`. Use `"cik": None` for tickers that do not file with the SEC.

### 3. Build the warehouse

dbt reads its connection settings from the `POSTGRES_*` environment variables:

```bash
export $(grep '^POSTGRES_' .env | xargs)
cd dbt_afive
uv run dbt run --profiles-dir .
uv run dbt test --profiles-dir .
```

The DAG only loads bronze, so re-run dbt after each ingestion to refresh the silver and gold tables.

### 4. Run the web app

```bash
cd stockValuation
composer run setup
```

`setup` installs dependencies, creates `.env` from `.env.example`, generates the app key, runs migrations and builds the frontend. The example file defaults to SQLite, so point `.env` at the warehouse and run the migrations again:

```dotenv
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=afive_dw
DB_USERNAME=afive_admin
DB_PASSWORD=<same password as data-platform/.env>
```

```bash
php artisan migrate
composer run dev
```

The app is then available at <http://localhost:8000>.

| Route | Page |
| --- | --- |
| `/dashboard` | Watchlist overview with latest price, multiples, margins and returns |
| `/companies/{ticker}` | Financial statements, peer comparison, valuation multiples and the DCF model |
| `POST /companies/{ticker}/scenarios` | Save a DCF scenario (base FCF, growth, terminal growth, WACC) |

## Development

```bash
# stockValuation/
composer run test       # lint check, type check and PHPUnit
composer run lint       # format PHP with Pint
npm run types:check     # TypeScript
```

## Known limitations

- Historical share counts are not adjusted for stock splits, so `shares_outstanding` jumps around a split date. The latest quarters, which drive the current valuation, are unaffected.
- `total_liabilities` stands in for debt in the enterprise value and DCF calculations.
- Companies without SEC filings fall back to a placeholder of one billion shares, so their market cap is not meaningful.
- `agg_industry_benchmarks` only includes tickers that traded on the most recent date in the price table.
