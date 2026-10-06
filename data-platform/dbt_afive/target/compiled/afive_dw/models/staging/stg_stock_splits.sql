-- One row per stock split: the ex-date and how many new shares replaced each old one
select
    upper(trim(s.ticker)) as ticker,
    e.key::date as split_date,
    e.value::numeric as split_ratio
from "afive_dw"."bronze"."raw_yf_fundamentals" s
cross join lateral jsonb_each_text(s.payload) as e
where s.statement_type = 'splits'