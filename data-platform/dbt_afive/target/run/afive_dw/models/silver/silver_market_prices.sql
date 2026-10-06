
      
        delete from "afive_dw"."silver"."silver_market_prices" as DBT_INTERNAL_DEST
        where (ticker, trade_date) in (
            select distinct ticker, trade_date
            from "silver_market_prices__dbt_tmp103810530051" as DBT_INTERNAL_SOURCE
        );

    

    insert into "afive_dw"."silver"."silver_market_prices" ("ticker", "trade_date", "open_price", "high_price", "low_price", "close_price", "adj_close", "volume", "dividend_amount", "split_coefficient", "daily_return", "dollar_volume", "sma_20", "sma_50", "updated_at")
    (
        select "ticker", "trade_date", "open_price", "high_price", "low_price", "close_price", "adj_close", "volume", "dividend_amount", "split_coefficient", "daily_return", "dollar_volume", "sma_20", "sma_50", "updated_at"
        from "silver_market_prices__dbt_tmp103810530051"
    )
  