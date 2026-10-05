with sec_entities as (
    select
        f.ticker,
        f.cik,
        coalesce(f.payload->>'entityName', s.payload->>'name') as company_name,
        -- SIC / industry only exist in the submissions payload (form_type = 'ENTITY');
        -- the companyfacts payload carries just cik, entityName and facts.
        s.payload->>'sic' as sic_code,
        nullif(s.payload->>'sicDescription', '') as industry_description
    from "afive_dw"."bronze"."raw_sec_filings" f
    left join "afive_dw"."bronze"."raw_sec_filings" s
        on f.cik = s.cik
        and s.form_type = 'ENTITY'
    where f.form_type = 'FACTS'
),

-- Yahoo Finance company profile: the only source of name / industry for non-SEC filers
yf_profiles as (
    select
        upper(trim(ticker)) as ticker,
        payload->>'longName' as company_name,
        payload->>'industry' as industry,
        payload->>'financialCurrency' as reporting_currency,
        payload->>'fullExchangeName' as exchange_name
    from "afive_dw"."bronze"."raw_yf_fundamentals"
    where statement_type = 'profile'
),

market_tickers as (
    select distinct ticker from "afive_dw"."bronze"."stg_market_prices"
),

combined as (
    select
        m.ticker,
        s.cik,
        coalesce(s.company_name, y.company_name, m.ticker) as company_name,
        coalesce(
            y.reporting_currency,
            case 
                when m.ticker like '%.KL' then 'MYR'
                else 'USD'
            end
        ) as reporting_currency,
        case 
            when m.ticker like '%.KL' then 'Bursa Malaysia'
            else 'US Equities (SEC)'
        end as primary_exchange,
        coalesce(s.industry_description, y.industry, 'General Equity') as industry
    from market_tickers m
    left join sec_entities s on m.ticker = s.ticker
    left join yf_profiles y on m.ticker = y.ticker
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