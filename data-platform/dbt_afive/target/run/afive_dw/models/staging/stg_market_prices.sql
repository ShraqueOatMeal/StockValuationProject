
  create view "afive_dw"."bronze"."stg_market_prices__dbt_tmp"
    
    
  as (
    with raw_data as (
    select * from "afive_dw"."bronze"."raw_market_prices"
),

cleaned as (
    select
        upper(trim(ticker)) as ticker,
        trade_date::date as trade_date,
        open_price::numeric(14, 4) as open_price,
        high_price::numeric(14, 4) as high_price,
        low_price::numeric(14, 4) as low_price,
        close_price::numeric(14, 4) as close_price,
        adj_close::numeric(14, 4) as adj_close,
        volume::bigint as volume,
        coalesce(dividend_amount::numeric(14, 4), 0.0) as dividend_amount,
        -- Rows ingested before the extractor fix carry Yahoo's 0.0 "no split" marker
        coalesce(nullif(split_coefficient, 0)::numeric(10, 4), 1.0) as split_coefficient,
        ingested_at
    from raw_data
)

select * from cleaned
  );