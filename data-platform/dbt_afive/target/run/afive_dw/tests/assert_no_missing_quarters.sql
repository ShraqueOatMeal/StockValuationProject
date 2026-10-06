
    
    select
      count(*) as failures,
      count(*) != 0 as should_warn,
      count(*) != 0 as should_error
    from (
      
    
  -- Fails when a company has a gap in its quarterly history: every calendar quarter between
-- its first and last reported period should be in fact_quarterly_financials
select
    ticker,
    fiscal_year,
    fiscal_period
from "afive_dw"."ops"."obs_filing_coverage"
where is_missing
  
  
      
    ) dbt_internal_test