with raw_statements as (
    select
        ticker,
        statement_type,
        frequency,
        payload
    from {{ source('bronze', 'raw_yf_fundamentals') }}
    -- The profile and splits rows are flat objects with their own models
    where statement_type in ('income', 'balance', 'cashflow')
),

-- Payload shape: { "<period end date>": { "<line item>": value, ... }, ... }
unnested as (
    select
        upper(trim(s.ticker)) as ticker,
        s.statement_type,
        s.frequency,
        p.key::date as period_end_date,
        i.key as line_item,
        i.value::numeric(24, 4) as amount
    from raw_statements s
    cross join lateral jsonb_each(s.payload) as p
    cross join lateral jsonb_each_text(p.value) as i
)

select * from unnested
