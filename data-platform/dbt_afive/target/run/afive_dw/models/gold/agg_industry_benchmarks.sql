
  
    

  create  table "afive_dw"."gold"."agg_industry_benchmarks__dbt_tmp"
  
  
    as
  
  (
    -- Each company's most recent valuation row. Tickers trade on different calendars, so the
-- latest date is taken per ticker rather than across the whole table.
with latest_valuation as (
    select distinct on (ticker) *
    from "afive_dw"."gold"."fact_daily_market_valuation"
    order by ticker, trade_date desc
)

select
    c.industry,
    count(distinct v.ticker) as peer_count,
    percentile_cont(0.5) within group (order by v.pe_ratio) as median_pe,
    percentile_cont(0.5) within group (order by v.p_fcf_ratio) as median_p_fcf,
    percentile_cont(0.5) within group (order by v.ev_sales_ratio) as median_ev_sales,
    percentile_cont(0.5) within group (order by v.ev_ebit_ratio) as median_ev_ebit
from latest_valuation v
join "afive_dw"."gold"."dim_company" c on v.company_sk = c.company_sk
group by c.industry
  );
  