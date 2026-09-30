with staged as (
    select * from {{ ref('stg_market_prices') }}
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
)

select * from enriched
