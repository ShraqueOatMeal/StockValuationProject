-- Source freshness looks at each raw table as a whole, so one ticker that has stopped
-- loading would be hidden by the others. This fails when any single ticker's prices have
-- not been loaded within the same seven-day limit.
select
    ticker,
    max(ingested_at) as last_ingested_at
from {{ source('bronze', 'raw_market_prices') }}
group by ticker
having max(ingested_at) < current_timestamp - interval '7 days'
