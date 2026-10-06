-- Fails when a company has a gap in its quarterly history: every calendar quarter between
-- its first and last reported period should be in fact_quarterly_financials
select
    ticker,
    fiscal_year,
    fiscal_period
from {{ ref('obs_filing_coverage') }}
where is_missing
