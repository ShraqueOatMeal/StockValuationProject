with scd2 as (
    select * from "afive_dw"."silver"."silver_financial_statements_scd2"
),

-- Map XBRL tags onto standardized line items. Filers switch between synonymous tags
-- from one filing to the next (e.g. Revenues <-> RevenueFromContractWithCustomer...),
-- so synonyms are resolved per reporting period rather than per company.
tag_map (gaap_tag, metric, tag_priority) as (
    values
        ('Revenues', 'revenue', 1),
        ('RevenueFromContractWithCustomerExcludingAssessedTax', 'revenue', 2),
        ('RevenueFromContractWithCustomerIncludingAssessedTax', 'revenue', 3),
        ('SalesRevenueNet', 'revenue', 4),
        ('GrossProfit', 'gross_profit', 1),
        ('CostOfRevenue', 'cost_of_revenue', 1),
        ('CostOfGoodsAndServicesSold', 'cost_of_revenue', 2),
        ('OperatingIncomeLoss', 'operating_income', 1),
        ('NetIncomeLoss', 'net_income', 1),
        ('NetCashProvidedByUsedInOperatingActivities', 'cfo', 1),
        ('PaymentsToAcquirePropertyPlantAndEquipment', 'capex', 1),
        ('Assets', 'total_assets', 1),
        ('AssetsCurrent', 'current_assets', 1),
        ('Liabilities', 'total_liabilities', 1),
        ('LiabilitiesCurrent', 'current_liabilities', 1),
        ('StockholdersEquity', 'stockholders_equity', 1),
        ('CashAndCashEquivalentsAtCarryingValue', 'cash_and_cash_equivalents', 1),
        ('CommonStockSharesOutstanding', 'shares_balance_sheet', 1),
        ('EntityCommonStockSharesOutstanding', 'shares_cover_page', 1),
        ('WeightedAverageNumberOfDilutedSharesOutstanding', 'shares_diluted_avg', 1)
),

mapped as (
    select
        s.ticker,
        s.cik,
        m.metric,
        m.tag_priority,
        s.period_start_date,
        s.period_end_date,
        s.amount,
        s.accession_number,
        s.valid_from,
        s.is_current
    from scd2 s
    join tag_map m on s.gaap_tag = m.gaap_tag
),

-- One value per metric and reporting period: latest filed version wins, tag priority breaks ties
current_facts as (
    select distinct on (ticker, metric, period_end_date, period_start_date)
        ticker,
        cik,
        metric,
        period_start_date,
        period_end_date,
        amount,
        -- Duration in days (NULL for balance sheet instants)
        period_end_date - period_start_date as duration_days
    from mapped
    where is_current = true
    order by ticker, metric, period_end_date, period_start_date, valid_from desc, tag_priority
),

flows as (
    select * from current_facts where period_start_date is not null
),

instants as (
    select * from current_facts where period_start_date is null
),

-- 1. Discrete 3-month flows reported directly (65 to 105 days)
direct_quarters as (
    select distinct on (ticker, metric, period_end_date)
        ticker,
        metric,
        period_end_date,
        amount
    from flows
    where duration_days between 65 and 105
    order by ticker, metric, period_end_date, duration_days desc
),

-- 2. Discrete flows derived from cumulative facts: YTD (or full year) minus the YTD
-- that shares the same start date and ends one quarter earlier. This covers Q4 (10-Ks
-- only report the full year) and cash flow items (10-Qs only report year-to-date).
derived_quarters as (
    select distinct on (c.ticker, c.metric, c.period_end_date)
        c.ticker,
        c.metric,
        c.period_end_date,
        c.amount - p.amount as amount
    from flows c
    join flows p
        on c.ticker = p.ticker
        and c.metric = p.metric
        and c.period_start_date = p.period_start_date
        and (c.period_end_date - p.period_end_date) between 65 and 105
    where c.duration_days > 105
    order by c.ticker, c.metric, c.period_end_date, c.duration_days
),

quarterly_flows as (
    select
        coalesce(d.ticker, y.ticker) as ticker,
        coalesce(d.metric, y.metric) as metric,
        coalesce(d.period_end_date, y.period_end_date) as period_end_date,
        coalesce(d.amount, y.amount) as amount
    from direct_quarters d
    full outer join derived_quarters y
        on d.ticker = y.ticker
        and d.metric = y.metric
        and d.period_end_date = y.period_end_date
),

flows_pivoted as (
    select
        ticker,
        period_end_date,
        max(amount) filter (where metric = 'revenue') as total_revenue,
        max(amount) filter (where metric = 'gross_profit') as reported_gross_profit,
        max(amount) filter (where metric = 'cost_of_revenue') as cost_of_revenue,
        max(amount) filter (where metric = 'operating_income') as operating_income,
        max(amount) filter (where metric = 'net_income') as net_income,
        max(amount) filter (where metric = 'cfo') as operating_cash_flow,
        max(amount) filter (where metric = 'capex') as capital_expenditures,
        max(amount) filter (where metric = 'shares_diluted_avg') as shares_diluted_avg
    from quarterly_flows
    group by ticker, period_end_date
),

-- 3. Balance Sheet & Shares (Instant values as at the quarter end)
instants_pivoted as (
    select
        ticker,
        period_end_date,
        max(amount) filter (where metric = 'total_assets') as total_assets,
        max(amount) filter (where metric = 'current_assets') as current_assets,
        max(amount) filter (where metric = 'total_liabilities') as total_liabilities,
        max(amount) filter (where metric = 'current_liabilities') as current_liabilities,
        max(amount) filter (where metric = 'stockholders_equity') as stockholders_equity,
        max(amount) filter (where metric = 'cash_and_cash_equivalents') as cash_and_cash_equivalents,
        max(amount) filter (where metric = 'shares_balance_sheet') as shares_balance_sheet
    from instants
    where metric <> 'shares_cover_page'
    group by ticker, period_end_date
),

-- Filing in which each period end was first reported. Later filings repeat the same
-- facts as prior-period comparatives, so the current SCD2 version carries a later date.
first_filings as (
    select distinct on (ticker, period_end_date)
        ticker,
        cik,
        period_end_date,
        valid_from as filing_date,
        accession_number
    from mapped
    where metric <> 'shares_cover_page'
    order by ticker, period_end_date, valid_from, accession_number
),

-- Quarter spine: one row per period end that has income statement / cash flow data
quarters as (
    select
        f.ticker,
        ff.cik,
        -- Label by the calendar quarter of the period end instead of the filing header's
        -- fy/fp, which describe the filing rather than the period the fact covers.
        extract(year from f.period_end_date)::int as fiscal_year,
        'Q' || extract(quarter from f.period_end_date)::text as fiscal_period,
        f.period_end_date,
        ff.filing_date,
        ff.accession_number,
        f.total_revenue,
        coalesce(f.reported_gross_profit, f.total_revenue - f.cost_of_revenue) as gross_profit,
        f.operating_income,
        f.net_income,
        i.total_assets,
        i.current_assets,
        i.total_liabilities,
        i.current_liabilities,
        i.stockholders_equity,
        i.cash_and_cash_equivalents,
        f.operating_cash_flow,
        f.capital_expenditures,
        -- Shares: balance sheet count, then the 10-Q/10-K cover page count (dated a few
        -- weeks after the period end), then the diluted weighted average for the quarter
        coalesce(i.shares_balance_sheet, cp.amount, f.shares_diluted_avg) as shares_outstanding
    from flows_pivoted f
    left join instants_pivoted i
        on f.ticker = i.ticker
        and f.period_end_date = i.period_end_date
    left join first_filings ff
        on f.ticker = ff.ticker
        and f.period_end_date = ff.period_end_date
    left join lateral (
        select c.amount
        from instants c
        where c.metric = 'shares_cover_page'
          and c.ticker = f.ticker
          and c.period_end_date > f.period_end_date
          and c.period_end_date <= f.period_end_date + 100
        order by c.period_end_date
        limit 1
    ) cp on true
),

ratios as (
  select
    -- Surrogate Key
    md5(concat_ws('||', ticker, fiscal_year, fiscal_period)) as financial_sk,
    md5(ticker) as company_sk,
    ticker,
    fiscal_year,
    fiscal_period,
    period_end_date,
    filing_date,
    accession_number,
    total_revenue,
    gross_profit,
    operating_income,
    net_income,
    total_assets,
    current_assets,
    total_liabilities,
    current_liabilities,
    stockholders_equity,
    cash_and_cash_equivalents,
    operating_cash_flow,
    capital_expenditures,
    shares_outstanding,

    -- Derived Free Cash Flow
    (operating_cash_flow - coalesce(capital_expenditures, 0)) as free_cash_flow,

    -- FCF / Net Income conversion (not meaningful when net income is zero or negative)
    case
        when net_income > 0
        then round((operating_cash_flow - coalesce(capital_expenditures, 0)) / net_income, 4)
    end as fcf_conversion,

    -- Financial Margins & Returns
    round(gross_profit / nullif(total_revenue, 0), 4) as gross_margin,
    round(operating_income / nullif(total_revenue, 0), 4) as operating_margin,
    round(net_income / nullif(total_revenue, 0), 4) as net_margin,
    round(net_income / nullif(stockholders_equity, 0), 4) as return_on_equity,
    round(total_liabilities / nullif(stockholders_equity, 0), 4) as debt_to_equity,
    round(current_assets / nullif(current_liabilities, 0), 4) as current_ratio,
    current_timestamp as computed_at
  from quarters
),

with_ttm as (
  select
    r.*,

    -- 4-Quarter Rolling TTM sums (NULL unless all four quarters are present)
    case when count(r.total_revenue) over w_ttm = 4 then sum(r.total_revenue) over w_ttm end as ttm_revenue,
    case when count(r.operating_income) over w_ttm = 4 then sum(r.operating_income) over w_ttm end as ttm_operating_income,
    case when count(r.net_income) over w_ttm = 4 then sum(r.net_income) over w_ttm end as ttm_net_income,
    case when count(r.free_cash_flow) over w_ttm = 4 then sum(r.free_cash_flow) over w_ttm end as ttm_fcf,
    case when count(r.operating_cash_flow) over w_ttm = 4 then sum(r.operating_cash_flow) over w_ttm end as ttm_operating_cash_flow,

    -- YoY Quarter Comparison (same quarter 1 year ago)
    py.total_revenue as prev_year_revenue,
    round(
      ((r.total_revenue - py.total_revenue) / nullif(py.total_revenue, 0)) * 100,
      2
    ) as revenue_yoy_growth
  from ratios r
  left join ratios py
    on r.ticker = py.ticker
    and py.fiscal_year = r.fiscal_year - 1
    and py.fiscal_period = r.fiscal_period
  window
    -- Date-based frame so a gap in the quarter history can't pull in older quarters
    w_ttm as (
      partition by r.ticker
      order by r.period_end_date
      range between interval '300 days' preceding and current row
    )
)

select * from with_ttm