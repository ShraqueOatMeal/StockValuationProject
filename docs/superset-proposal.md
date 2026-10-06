# Proposal: Exploratory Analytics with Apache Superset (revised)

**Project:** AFIVE Analytics Workstation
**Status:** Phase 1 is built: infrastructure, data models and four starter dashboards (seeded by `data-platform/docker/superset/bootstrap_dashboards.py`). Phase 2 (embedding) is deferred.

## 1. Rationale

The Laravel/React app is the right home for anything that depends on user input: the two DCF models, the maintenance CapEx slider, saved scenarios. It is a poor home for exploration. Every new comparison needs a controller query, a TypeScript interface and a chart component.

Superset fills that gap. It reads the gold tables directly, so a new chart is a few clicks rather than a deployment.

| Laravel + React | Superset |
| --- | --- |
| Interactive DCF models and sensitivity matrix | Screening across companies |
| Saved scenarios | Quality-of-earnings and DuPont trends |
| Company page and statements table | Peer and industry comparison |
| | Pipeline health |

**One rule carries over from the rest of the project: all metric logic lives in dbt.** Superset charts columns that already exist; it does not define formulas. A ratio defined in Superset's semantic layer would be invisible to the Laravel app and to anyone querying the warehouse.

## 2. What changed from the original proposal

| Original | Revised | Why |
| --- | --- | --- |
| Four dashboards built around cross-sectional statistics (box plots, regression lines, outliers beyond two standard deviations) | Dashboards that work per company and over time first; cross-sectional views once the watchlist is larger | The warehouse holds three companies in three different industries. A box plot of one company per industry shows nothing. |
| Sloan ratio, FCF conversion and median premium defined as Superset metrics | Added as dbt columns and models | Keeps one source of truth. The original also referenced columns that do not exist (`sector_median_pe`) and a second, conflicting definition of FCF conversion. |
| Net debt as total liabilities minus cash | Uses `total_debt` | The warehouse has had a real debt figure since the valuation work; total liabilities overstates debt badly for banks and for any company with deferred revenue. |
| Restatements counted as SCD2 rows where `is_current = false` | New model that keeps only versions whose amount changed | Most non-current rows are the same number repeated as a prior-year comparative, not restatements. |
| Superset metadata in the `afive_dw` database, connecting as `postgres:postgres` | Separate `superset` database and role; warehouse queried through a read-only role | Those credentials do not exist here, and Superset's sixty-odd tables would land next to Airflow's and Laravel's. |
| Hard-coded secret with a default value, reused as the guest-token secret | Secrets generated into `.env`, no defaults, separate guest-token secret | A committed default secret is a known key. |
| `X-Frame-Options: ALLOWALL` and guest role `Public` | Framing limited to the app's origin; guest role `Gamma` (Phase 2) | `ALLOWALL` lets any site frame the dashboards. |
| Port 8088 published on all interfaces | Bound to `127.0.0.1` | Nothing outside this machine needs it. |
| Second Redis container for caching | In-process cache, no Redis | The gold tables are a few hundred rows and change once a day. |
| `apache/superset:3.1.0`, `GENERIC_CHART_AXES` flag | `apache/superset:6.0.0` with the PostgreSQL driver added | 3.1 is three major versions old and that flag no longer exists. The current image ships without database drivers. |
| No initialisation step | One-shot `superset-init` service | Superset needs its database migrated and an admin created before it will start. |
| Embedding via guest tokens in week 3 | Deferred to Phase 2; a sidebar link opens Superset for now | Dashboards have to exist before they can be embedded, and the app is single-user with no login on its routes, so guest tokens would protect nothing yet. |
| Composite indexes on gold tables | Dropped | Not needed at this size. |
| Four-week plan for analysts and administrators | Two phases for one developer | Matches who is actually using it. |

## 3. Data models added to dbt

| Object | Purpose |
| --- | --- |
| `fact_quarterly_financials.asset_turnover`, `equity_multiplier` | DuPont: ROE = net margin × asset turnover × equity multiplier |
| `fact_quarterly_financials.accruals_ratio`, `normalized_accruals_ratio` | Sloan ratio: (net income − operating cash flow) ÷ total assets. The normalized variant excludes investment gains, which are non-cash and would otherwise look like aggressive accounting. |
| `gold.mart_valuation_screener` | One row per company: latest multiples, yields, growth, quality, both fair values, industry medians and premium to industry |
| `ops.obs_filing_coverage` | Every expected quarter per company: missing or present, source, filing lag, empty core fields |
| `ops.obs_restatements` | Facts whose amount changed between filings, with old and new values |
| dbt source freshness and two tests | Stale raw tables, a single stale ticker, or a missing quarter fail the Airflow run instead of only showing on a dashboard |
| `gold.agg_industry_benchmarks` (fixed) | Now uses each company's latest row instead of the latest date in the whole table |

## 4. Dashboards

**Phase 1: useful with three companies**

| Dashboard | Dataset | Charts |
| --- | --- | --- |
| Quality of earnings | `fact_quarterly_financials` | Net income against operating cash flow by quarter; normalized accruals ratio line; CapEx against D&A and maintenance CapEx; DuPont components over time. Filter by ticker. |
| Valuation over time | `fact_daily_market_valuation` | Price against both fair values; margin of safety; P/E and normalized P/E. Filter by ticker. |
| Screener | `mart_valuation_screener` | Table of all companies with multiples, yields, growth, fair values and margin of safety; bar charts ranking each. |
| Pipeline health | `obs_*` | Coverage grid (ticker × year × quarter); filing lag by quarter; restatements by filing date. |

**Later: once the watchlist reaches roughly twenty companies or more**

P/E against growth scatter with a trend line, multiple distributions by industry, premium-to-industry bars and return-on-equity against growth quadrants. The screener model already carries every column these need.

## 5. Architecture

```
Yahoo Finance, SEC EDGAR
        │  Airflow
        ▼
   bronze ──dbt──► silver ──dbt──► gold ◄── afive_readonly (15s statement timeout)
                                    ▲                 │
              Laravel + React ──────┘                 ▼
                     │                           Superset :8088 (localhost only)
                     └──── sidebar link ──────────────┘
                                                      │
                                              database "superset" (metadata)
```

- Superset connects to the warehouse as `afive_readonly`, which can read `gold`, `silver` and `ops` only.
- Its own users, charts and dashboards are stored in a separate `superset` database on the same Postgres server.

## 6. Phase 2: embedding (not built)

When the dashboards are settled and the app has authenticated routes:

1. Turn on `EMBEDDED_SUPERSET` and the guest-token settings (already sketched, commented out, in `superset_config.py`).
2. Add a Laravel endpoint that requests a guest token using a dedicated Superset service account, not the admin login.
3. In React, pass `fetchGuestToken` a function that calls that endpoint, so the token refreshes instead of expiring after its lifetime.
4. Restrict framing and CORS to the app's origin.

Corrections to the original sample code: the option is `supersetDomain` (it was misspelled once), the app runs Laravel 13 rather than 11, and passing the token as a page prop means it cannot be refreshed.

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| An exploratory query slows the warehouse | Read-only role with a 15-second statement timeout |
| Metric definitions drift between tools | Formulas only in dbt; Superset charts columns |
| Dashboards are lost if the Postgres volume is deleted | Export dashboards from Superset (Settings → Export) and commit the files |
| Small sample misleads | Cross-sectional dashboards wait for a larger watchlist |
