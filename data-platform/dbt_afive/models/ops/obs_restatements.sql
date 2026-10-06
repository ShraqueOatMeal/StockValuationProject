-- Pipeline observability: facts whose reported value changed between filings. Most SCD2
-- versions are the same number repeated as a prior-period comparative; only the versions
-- where the amount actually differs are restatements.
with versions as (
    select
        ticker,
        gaap_tag,
        unit,
        period_start_date,
        period_end_date,
        form_type,
        accession_number,
        valid_from,
        amount,
        lag(amount) over w_fact as previous_amount,
        lag(accession_number) over w_fact as previous_accession_number,
        lag(valid_from) over w_fact as previously_filed_on
    from {{ ref('silver_financial_statements_scd2') }}
    window w_fact as (
        partition by ticker, gaap_tag, period_end_date, coalesce(period_start_date, '1900-01-01'::date)
        order by valid_from, accession_number
    )
)

select
    ticker,
    gaap_tag,
    unit,
    period_start_date,
    period_end_date,
    form_type,
    accession_number,
    valid_from as restated_on,
    previous_accession_number,
    previously_filed_on,
    -- Share counts are restated after every stock split; those are not accounting changes
    case when unit = 'shares' then 'share_count' else 'financial' end as restatement_type,
    previous_amount,
    amount as restated_amount,
    amount - previous_amount as change_amount,
    round((amount - previous_amount) / nullif(abs(previous_amount), 0) * 100, 2) as change_pct
from versions
where previous_amount is not null
  and amount <> previous_amount
