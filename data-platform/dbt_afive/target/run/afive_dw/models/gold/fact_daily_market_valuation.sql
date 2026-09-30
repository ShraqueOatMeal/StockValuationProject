
  
    

  create  table "afive_dw"."gold"."fact_daily_market_valuation__dbt_tmp"
  
  
    as
  
  (
    with prices as (
    select * from "afive_dw"."silver"."silver_market_prices"
),

financials as (
    select * from "afive_dw"."gold"."fact_quarterly_financials"
),

joined as (
    select
        -- Daily Surrogate Key
        md5(concat_ws('||', p.ticker, p.trade_date)) as valuation_sk,
        md5(p.ticker) as company_sk,
        p.ticker,
        p.trade_date,
        p.close_price,
        p.adj_close,
        p.volume,
        p.dollar_volume,
        p.daily_return,
        p.sma_20,
        p.sma_50,
        p.dividend_amount,

        -- Point-in-time Financials linkage
        f.fiscal_year as latest_filed_year,
        f.fiscal_period as latest_filed_period,
        f.filing_date,
        f.total_revenue,
        f.net_income,
        f.operating_cash_flow,
        f.free_cash_flow,
        f.net_margin,
        f.return_on_equity,

        -- Price-to-Performance indicators (Relative Yield)
        round(p.dividend_amount / nullif(p.adj_close, 0), 6) as daily_dividend_yield,
        current_timestamp as calculated_at
    from prices p
    left join lateral (
        select *
        from financials f
        where f.ticker = p.ticker
          and f.filing_date <= p.trade_date
        order by f.filing_date desc, f.period_end_date desc
        limit 1
    ) f on true
)

select * from joined
  );
  