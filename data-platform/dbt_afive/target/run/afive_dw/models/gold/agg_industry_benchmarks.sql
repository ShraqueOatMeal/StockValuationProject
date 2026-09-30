
  
    

  create  table "afive_dw"."gold"."agg_industry_benchmarks__dbt_tmp"
  
  
    as
  
  (
    select
    c.industry,
    count(distinct v.ticker) as peer_count,
    percentile_cont(0.5) within group (order by v.pe_ratio) as median_pe,
    percentile_cont(0.5) within group (order by v.p_fcf_ratio) as median_p_fcf,
    percentile_cont(0.5) within group (order by v.ev_sales_ratio) as median_ev_sales,
    percentile_cont(0.5) within group (order by v.ev_ebit_ratio) as median_ev_ebit
from "afive_dw"."gold"."fact_daily_market_valuation" v
join "afive_dw"."gold"."dim_company" c on v.company_sk = c.company_sk
where v.trade_date = (select max(trade_date) from "afive_dw"."gold"."fact_daily_market_valuation")
group by c.industry
  );
  