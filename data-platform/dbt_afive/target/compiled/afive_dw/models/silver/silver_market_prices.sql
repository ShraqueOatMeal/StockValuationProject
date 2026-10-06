

with staged as (
    select * from "afive_dw"."bronze"."stg_market_prices"
),


-- Earliest trade date ingested since the last run. Everything from that date onwards is
-- recalculated, because returns and moving averages depend on the rows before them; a
-- backfill of old history therefore widens the window on its own.
changed as (
    select min(trade_date) as from_date
    from staged
    where ingested_at > (select coalesce(max(updated_at), '1900-01-01') from "afive_dw"."silver"."silver_market_prices")
),


enriched as (
    select
        ticker,
        trade_date,
        open_price,
        high_price,
        low_price,
        close_price,
        adj_close,
        volume,
        dividend_amount,
        split_coefficient,
        -- Daily percentage change in adjusted close
        round(
            (adj_close - lag(adj_close) over (partition by ticker order by trade_date)) 
            / nullif(lag(adj_close) over (partition by ticker order by trade_date), 0),
            6
        ) as daily_return,
        -- Liquidity metric: Traded Dollar Volume
        round(close_price * volume, 2) as dollar_volume,
        -- 20-Day and 50-Day Simple Moving Averages
        round(avg(adj_close) over (
            partition by ticker 
            order by trade_date 
            rows between 19 preceding and current row
        ), 4) as sma_20,
        round(avg(adj_close) over (
            partition by ticker 
            order by trade_date 
            rows between 49 preceding and current row
        ), 4) as sma_50,
        ingested_at as updated_at
    from staged
    
    -- 100 calendar days of earlier history so the 50-day average is complete at the cutoff
    where trade_date >= (select from_date from changed) - 100
    
)

select * from enriched

where trade_date >= (select from_date from changed)
