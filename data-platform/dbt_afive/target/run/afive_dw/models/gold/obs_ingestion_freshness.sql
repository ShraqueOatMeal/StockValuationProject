
  
    

  create  table "afive_dw"."gold"."obs_ingestion_freshness__dbt_tmp"
  
  
    as
  
  (
    -- Pipeline observability: when each source last landed data for each ticker
select
    'yahoo_prices' as source,
    upper(trim(ticker)) as ticker,
    count(*) as row_count,
    max(trade_date) as latest_data_date,
    max(ingested_at) as last_ingested_at,
    current_timestamp as checked_at
from "afive_dw"."bronze"."raw_market_prices"
group by 2

union all

select
    'yahoo_fundamentals' as source,
    upper(trim(ticker)) as ticker,
    count(*) as row_count,
    null::date as latest_data_date,
    max(ingested_at) as last_ingested_at,
    current_timestamp as checked_at
from "afive_dw"."bronze"."raw_yf_fundamentals"
group by 2

union all

select
    'sec_edgar' as source,
    upper(trim(ticker)) as ticker,
    count(*) as row_count,
    null::date as latest_data_date,
    max(ingested_at) as last_ingested_at,
    current_timestamp as checked_at
from "afive_dw"."bronze"."raw_sec_filings"
group by 2
  );
  