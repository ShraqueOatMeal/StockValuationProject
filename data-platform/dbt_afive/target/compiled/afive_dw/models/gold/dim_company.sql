with sec_entities as (
    select
        ticker,
        cik,
        payload->>'entityName' as company_name,
        payload->>'sic' as sic_code,
        payload->>'sicDescription' as industry_description
    from "afive_dw"."bronze"."raw_sec_filings"
),

market_tickers as (
    select distinct ticker from "afive_dw"."bronze"."stg_market_prices"
),

combined as (
    select
        m.ticker,
        s.cik,
        coalesce(s.company_name, m.ticker) as company_name,
        case 
            when m.ticker like '%.KL' then 'MYR'
            else 'USD'
        end as reporting_currency,
        case 
            when m.ticker like '%.KL' then 'Bursa Malaysia'
            else 'US Equities (SEC)'
        end as primary_exchange,
        coalesce(s.industry_description, 'General Equity') as industry
    from market_tickers m
    left join sec_entities s on m.ticker = s.ticker
)

select
    -- Surrogate Key
    md5(ticker) as company_sk,
    ticker,
    cik,
    company_name,
    reporting_currency,
    primary_exchange,
    industry,
    true as is_active,
    current_timestamp as created_at
from combined