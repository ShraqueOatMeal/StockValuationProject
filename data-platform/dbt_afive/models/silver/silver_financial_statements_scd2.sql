with staged_facts as (
    select * from {{ ref('stg_sec_facts') }}
),

ordered_facts as (
    select
        ticker,
        cik,
        gaap_tag,
        form_type,
        fiscal_year,
        fiscal_period,
        period_start_date,
        period_end_date,
        amount,
        accession_number,
        filed_date as valid_from,
        lead(filed_date) over (
            partition by ticker, fiscal_year, fiscal_period, gaap_tag 
            order by filed_date asc, accession_number asc
        ) as next_filed_date,
        row_number() over (
            partition by ticker, fiscal_year, fiscal_period, gaap_tag 
            order by filed_date desc, accession_number desc
        ) as recency_rank
    from staged_facts
),

scd2 as (
    select
        -- Surrogate Key
        md5(concat_ws('||', ticker, fiscal_year, fiscal_period, gaap_tag, valid_from)) as statement_sk,
        ticker,
        cik,
        gaap_tag,
        form_type,
        fiscal_year,
        fiscal_period,
        period_start_date,
        period_end_date,
        amount,
        accession_number,
        valid_from,
        coalesce(next_filed_date, '9999-12-31'::date) as valid_to,
        case when recency_rank = 1 then true else false end as is_current,
        current_timestamp as dbt_updated_at
    from ordered_facts
)

select * from scd2
