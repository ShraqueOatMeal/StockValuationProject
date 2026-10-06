# Stock Valuation Project (AFIVE)

A stock valuation workbench in two parts:

- **`data-platform/`** — a medallion-style data warehouse on PostgreSQL. Airflow ingests daily prices and fundamentals from Yahoo Finance and XBRL financial statements from SEC EDGAR; dbt turns them into quarterly financials and daily valuation multiples.
- **`stockValuation/`** — a Laravel + Inertia + React app that reads the warehouse and provides a valuation dashboard, per-company financial statements, peer comparison and an interactive owner-earnings DCF model with saved scenarios.

The watchlist currently covers Alphabet (`GOOGL`), ServiceNow (`NOW`) and Malayan Banking (`1155.KL`). SEC filers get their full filing history; the Bursa Malaysia ticker relies on Yahoo Finance, which only serves the last five quarters.

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
  dags/dag_market_eod.py        Airflow DAGs: daily ingestion + incremental dbt (Mon–Fri 22:00 UTC),
                                weekly price re-pull + full dbt rebuild (Sun 03:00 UTC)
  src/extractors/               market_data.py and fundamentals.py (Yahoo Finance), sec_edgar.py (SEC EDGAR)
  src/common/db.py              PostgreSQL connection helper
  dbt_afive/                    dbt project (staging / silver / gold models)
  docker/postgres/              Schema and bronze table DDL, run on first database start
  docker/superset/              Superset image, config and dataset bootstrap script
  docker-compose.yml            PostgreSQL, Redis, Airflow webserver + scheduler, Superset
stockValuation/
  app/Http/Controllers/         ValuationDashboardController, CompanyValuationController
  app/Models/                   Company, QuarterlyFinancial, DailyMarketValuation, UserDcfScenario
  resources/js/pages/           Dashboard.tsx, companies/show.tsx
```

## Data model

| Layer | Object | What it holds |
| --- | --- | --- |
| bronze | `raw_market_prices` | Daily OHLCV, adjusted close, dividends and splits per ticker |
| bronze | `raw_yf_fundamentals` | One JSONB row per ticker, statement (income, balance, cash flow) and frequency (quarterly, annual) from Yahoo Finance, plus one row each for the company profile and the stock split history |
| bronze | `raw_sec_filings` | One JSONB row per company and payload type: `FACTS` (XBRL company facts) and `ENTITY` (SIC code, industry, exchanges) |
| staging | `stg_market_prices`, `stg_sec_facts`, `stg_yf_fundamentals` | Typed views over bronze; `stg_sec_facts` unnests the selected XBRL tags into one row per reported fact, `stg_yf_fundamentals` one row per line item and period |
| silver | `silver_market_prices` | Prices with daily return, dollar volume and 20/50-day moving averages |
| silver | `silver_financial_statements_scd2` | Every filed version of each fact, with `valid_from` / `valid_to` / `is_current` so restatements are tracked |
| gold | `dim_company` | Ticker, name, currency, exchange and industry (SEC entity data, then the Yahoo Finance profile) |
| gold | `fact_quarterly_financials` | One row per company and quarter: income statement, balance sheet and cash flow items, margins, TTM sums and YoY growth |
| gold | `fact_daily_market_valuation` | Daily price joined to the latest financials filed on or before that date: market cap, enterprise value, P/E, P/FCF, EV/Sales, EV/EBIT, base-case fair value and margin of safety |
| gold | `agg_industry_benchmarks` | Median multiples per industry, from each company's latest valuation |
| gold | `mart_valuation_screener` | One row per company: latest multiples, yields, growth, quality, fair values and premium to industry |
| ops | `obs_filing_coverage`, `obs_restatements` | Pipeline monitoring, kept outside the three data layers: missing quarters and filing lag, and facts whose value changed between filings |

Notes on `fact_quarterly_financials`:

- Quarterly flows are the directly reported three-month figure where one exists, otherwise year-to-date minus the previous year-to-date. This is how Q4 and cash flow items are derived, since 10-Ks report only the full year and 10-Qs report cash flows year-to-date.
- SEC data is the primary source. Yahoo Finance fills line items the XBRL data lacks and supplies whole quarters for companies with no SEC filings; `data_source` says which. Yahoo Finance has no filing dates, so those quarters are assumed public 60 days after the period end.
- Share counts are on today's share basis. A count is multiplied by every split that took effect after the filing it was last reported in (`stg_stock_splits`, from Yahoo Finance); filings made after a split already show adjusted figures.
- `fiscal_year` and `fiscal_period` are the calendar year and quarter of the period end date.
- `filing_date` is the first filing that reported the period, which keeps the join in `fact_daily_market_valuation` point-in-time.
- `normalized_net_income` is GAAP net income less after-tax gains (plus losses) on investment securities, taxed at the trailing effective rate (kept within 0–35%). Interest and other non-operating income stay in. `normalized_eps` and `eps_diluted` divide normalized and GAAP net income by diluted shares.
- `true_owner_earnings` follows Buffett's definition, applied to normalized earnings: normalized net income, plus depreciation and amortization, less maintenance CapEx. Maintenance CapEx is proxied by D&A, capped at actual CapEx. Reported D&A is always used when any source has it: the quarterly figure from the SEC filing, then from Yahoo Finance, then the annual figure (SEC, then Yahoo Finance) allocated to the quarters that lack their own. Only when no D&A is reported at all is depreciation estimated from the net PP&E roll-forward (opening net PP&E + CapEx − closing net PP&E). `depreciation_source` records which one was used, and `maintenance_capex_is_estimated` flags the estimate.
- Margins and `fcf_conversion` are stored as ratios (0.6165 = 61.65%); the Laravel controllers convert them to percentages for display.

### Fair value

`fact_daily_market_valuation` carries two DCF fair values, shown as two tabs on the company page. Both project 10 years of growth in two stages and then a Gordon Growth terminal value. Their base cash flows are after interest, so the discounted value is equity value: debt is not subtracted and cash is not added, since interest paid and earned are already in the cash flows. Long-term investments (`non_operating_investments`) are added because their gains are excluded from the base.

| | Conservative | Franchise |
| --- | --- | --- |
| Columns | `fair_value_per_share`, `margin_of_safety` | `franchise_fair_value_per_share`, `franchise_margin_of_safety` |
| Base cash flow (TTM) | True Owner Earnings: normalized net income + D&A − maintenance CapEx | Cash Owner Earnings: operating cash flow − maintenance CapEx |
| Growth | 10% for years 1–5, 7% for years 6–10 | 15% for years 1–5, 10% for years 6–10 |
| Terminal growth / discount rate | 2.5% / 8.5% | 2.5% / 8.5% |

The assumptions are dbt vars in `dbt_afive/dbt_project.yml` (`dcf_*` and `dcf_franchise_*`). The company page starts from these values and recalculates the selected model in the browser as the sliders move; that what-if calculation cannot live in dbt because it depends on user input.

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
uv run python src/extractors/fundamentals.py  # Yahoo Finance statements
```

On each run the daily DAG loads prices from the last stored trade date onward (with a 7-day overlap), so a new ticker gets one year of history automatically and a gap left by downtime fills itself.

To add a company, append it to `WATCHLIST` in `dags/dag_market_eod.py`. Use `"cik": None` for tickers that do not file with the SEC.

### 3. Build the warehouse

dbt reads its connection settings from the `POSTGRES_*` environment variables:

```bash
export $(grep '^POSTGRES_' .env | xargs)
cd dbt_afive
uv run dbt run --profiles-dir .
uv run dbt test --profiles-dir .
```

Both DAGs finish with `dbt build`, so the silver and gold tables refresh without a manual step. Run dbt by hand only after changing a model, and add `--full-refresh` when you do: the two price models are incremental and will not recalculate history on their own.

### Orchestration and refresh windows

| | Daily (`dag_market_eod`) | Weekly (`dag_weekly_full_refresh`) |
| --- | --- | --- |
| Schedule | Mon–Fri 22:00 UTC | Sunday 03:00 UTC |
| Prices fetched | From the last stored trade date, less 7 days; one year for a ticker with no history | The full one-year window, because Yahoo restates adjusted closes after dividends and splits |
| Fundamentals and SEC | Fetched | Not fetched |
| dbt | `dbt source freshness`, then `dbt build`: price models reprocess only newly ingested dates plus a trailing 10 days | `dbt source freshness`, then `dbt build --full-refresh`: every model rebuilt from scratch |

Three checks can fail a run before or while the models build:

- **Source freshness** (`sources.yml`): warns when a raw table has not been loaded for 4 days and fails at 7. Loads run on weekdays, so a normal weekend gap is about three days.
- **`assert_every_ticker_loaded_recently`**: fails when any single ticker's prices have not loaded for 7 days, which table-level freshness would miss.
- **`assert_no_missing_quarters`**: fails when a company has a gap in its quarterly history.

`silver_market_prices` and `fact_daily_market_valuation` are incremental. The financial statement models are small and are rebuilt in full on every run. The windows are set by `PRICE_BACKFILL_PERIOD` and `PRICE_LOOKBACK_DAYS` in the DAG file and `incremental_lookback_days` in `dbt_project.yml`.

dbt runs inside the Airflow containers from its own virtual environment, with `dbt_afive/` mounted into them. After pulling these changes, rebuild the image once: `docker compose build && docker compose up -d`.

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

### 5. Exploratory analytics (Superset)

Apache Superset runs alongside the app for ad-hoc charts and dashboards over the gold tables. It queries the warehouse through a read-only role and keeps its own metadata in a separate `superset` database. The design and the dashboards to build are in [`docs/superset-proposal.md`](docs/superset-proposal.md).

Add these to `data-platform/.env` (any long random strings):

```dotenv
SUPERSET_SECRET_KEY=<random>
SUPERSET_DB_PASSWORD=<random>
WAREHOUSE_READONLY_PASSWORD=<random>
SUPERSET_ADMIN_USER=admin
SUPERSET_ADMIN_PASSWORD=<random>
```

```bash
cd data-platform
docker compose up -d --build
```

Everything runs inside Docker. Three one-shot services do the setup and then exit: `superset-db-init` creates the `superset` database and the read-only role and resets their passwords to match `.env`, `superset-init` migrates Superset's metadata and creates the admin user, and `superset-bootstrap` registers the gold tables as datasets and seeds four starter dashboards. They run on every `up`, so changing a password in `.env` only needs another `docker compose up -d`.

| Dashboard | What it shows |
| --- | --- |
| Quality of Earnings | Net income against operating cash flow, accruals, CapEx against depreciation, owner earnings and the DuPont breakdown, for one company at a time |
| Valuation Over Time | Price against both fair values, margin of safety and P/E, for one company at a time |
| Screener | Every company side by side: fair values, multiples, yields, growth |
| Pipeline Health | Quarters held, missing quarters, filing lag and restatements |

The dashboards are defined in `docker/superset/bootstrap_dashboards.py`. Once created they are left alone, so edits made in the Superset UI survive restarts; run `SUPERSET_REBUILD_DASHBOARDS=1 docker compose up superset-bootstrap` to rebuild them from the file, which discards UI edits to those four. Give it a slug instead of `1` (for example `SUPERSET_REBUILD_DASHBOARDS=pipeline-health`) to rebuild just one.

Superset is then at <http://localhost:8088>, reachable from this machine only; sign in with the admin user from `.env`. The web app's sidebar links to it. All metric formulas stay in dbt: Superset charts existing columns and defines none of its own.

## Development

```bash
# stockValuation/
composer run test       # lint check, type check and PHPUnit
composer run lint       # format PHP with Pint
npm run types:check     # TypeScript
```

## Known limitations

- Share counts from Yahoo Finance (used only where SEC has none) are taken as already split-adjusted.
- Enterprise value and the EV multiples use `total_debt` (Yahoo Finance, then XBRL debt tags). Older quarters with neither fall back to total liabilities.
- Maintenance CapEx is never reported, so it is estimated. The gold tables carry two estimates as a share of trailing CapEx: `maintenance_capex_share` (D&A proxy, the default) and `greenwald_maintenance_capex_share` (CapEx less the plant needed for the year's sales growth). The company page shows both as markers on a slider.
- Both DCF models default to maintenance CapEx roughly equal to D&A. If more of a company's CapEx is really needed to sustain its earnings, its owner earnings and fair value are overstated.
- Banks such as 1155.KL report no gross profit, current assets, current liabilities or operating income. The first three stay empty; pre-tax profit stands in for operating income. An owner earnings DCF is also a rough fit for a bank, so treat its fair value with caution.
- Yahoo Finance serves only the latest five quarters and four fiscal years. The extractor keeps periods it has already stored, so history accumulates from the first run onward.
- `docker/postgres/init_schemas.sql` only runs when the database volume is first created. On an existing database, run the `raw_yf_fundamentals` statement from that file by hand.
