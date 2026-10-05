
  create view "afive_dw"."bronze"."stg_yf_fundamentals__dbt_tmp"
    
    
  as (
    with raw_statements as (
    select
        ticker,
        statement_type,
        frequency,
        payload
    from "afive_dw"."bronze"."raw_yf_fundamentals"
    -- The company profile row is a flat object, read directly by dim_company
    where statement_type <> 'profile'
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
  );