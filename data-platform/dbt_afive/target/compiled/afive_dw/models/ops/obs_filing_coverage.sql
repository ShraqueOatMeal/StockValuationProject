-- Pipeline observability: every calendar quarter between a company's first and last
-- reported period, whether the warehouse holds it, and how complete and timely it is.
with financials as (
    select * from "afive_dw"."gold"."fact_quarterly_financials"
),

bounds as (
    select
        ticker,
        min(period_end_date) as first_period,
        max(period_end_date) as last_period
    from financials
    group by ticker
),

expected_quarters as (
    select
        b.ticker,
        extract(year from q)::int as fiscal_year,
        'Q' || extract(quarter from q)::text as fiscal_period,
        (q + interval '3 months' - interval '1 day')::date as quarter_end_date
    from bounds b
    cross join lateral generate_series(
        date_trunc('quarter', b.first_period),
        date_trunc('quarter', b.last_period),
        interval '3 months'
    ) as q
)

select
    e.ticker,
    e.fiscal_year,
    e.fiscal_period,
    e.quarter_end_date,
    f.ticker is null as is_missing,
    f.data_source,
    f.depreciation_source,
    f.period_end_date,
    f.filing_date,
    -- Days from period end to first filing (Yahoo Finance quarters carry an assumed date)
    case when f.data_source = 'sec' then f.filing_date - f.period_end_date end as filing_lag_days,
    -- A lag beyond 120 days means the quarter first reached the warehouse as a prior-period
    -- comparative in a later filing (pre-IPO periods, or history filed under an earlier
    -- SEC registrant), not that the company filed late
    case when f.data_source = 'sec' then (f.filing_date - f.period_end_date) <= 120 end as is_original_filing,
    -- Core line items that are empty for the quarter, out of eight
    (f.total_revenue is null)::int
        + (f.operating_income is null)::int
        + (f.net_income is null)::int
        + (f.operating_cash_flow is null)::int
        + (f.capital_expenditures is null)::int
        + (f.total_assets is null)::int
        + (f.stockholders_equity is null)::int
        + (f.shares_outstanding is null)::int as missing_core_fields
from expected_quarters e
left join financials f
    on e.ticker = f.ticker
    and e.fiscal_year = f.fiscal_year
    and e.fiscal_period = f.fiscal_period