
  
    

  create  table "afive_dw"."gold"."fact_quarterly_financials__dbt_tmp"
  
  
    as
  
  (
    with scd2_current as (
    select *
    from "afive_dw"."silver"."silver_financial_statements_scd2"
    where is_current = true
),

pivoted as (
    select
        ticker,
        cik,
        fiscal_year,
        fiscal_period,
        max(period_end_date) as period_end_date,
        max(valid_from) as filing_date,
        max(accession_number) as accession_number,

        -- Income Statement Line Items
        max(case when gaap_tag in ('Revenues', 'SalesRevenueNet') then amount end) as total_revenue,
        max(case when gaap_tag = 'OperatingIncomeLoss' then amount end) as operating_income,
        max(case when gaap_tag = 'NetIncomeLoss' then amount end) as net_income,

        -- Balance Sheet Line Items
        max(case when gaap_tag = 'Assets' then amount end) as total_assets,
        max(case when gaap_tag = 'AssetsCurrent' then amount end) as current_assets,
        max(case when gaap_tag = 'Liabilities' then amount end) as total_liabilities,
        max(case when gaap_tag = 'LiabilitiesCurrent' then amount end) as current_liabilities,
        max(case when gaap_tag = 'StockholdersEquity' then amount end) as stockholders_equity,
        max(case when gaap_tag = 'CashAndCashEquivalentsAtCarryingValue' then amount end) as cash_and_cash_equivalents,

        -- Cash Flow Statement Line Items
        max(case when gaap_tag = 'NetCashProvidedByUsedInOperatingActivities' then amount end) as operating_cash_flow,
        max(case when gaap_tag = 'PaymentsToAcquirePropertyPlantAndEquipment' then amount end) as capital_expenditures,

        -- Share Count Line Item
        max(case when gaap_tag in (
            'EntityCommonStockSharesOutstanding',
            'CommonStockSharesOutstanding',
            'WeightedAverageNumberOfDilutedSharesOutstanding'
        ) then amount end) as shares_outstanding
    from scd2_current
    group by ticker, cik, fiscal_year, fiscal_period
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
        (coalesce(operating_cash_flow, 0) - coalesce(capital_expenditures, 0)) as free_cash_flow,

        -- Financial Margins & Returns
        round(operating_income / nullif(total_revenue, 0), 4) as operating_margin,
        round(net_income / nullif(total_revenue, 0), 4) as net_margin,
        round(net_income / nullif(stockholders_equity, 0), 4) as return_on_equity,
        round(total_liabilities / nullif(stockholders_equity, 0), 4) as debt_to_equity,
        round(current_assets / nullif(current_liabilities, 0), 4) as current_ratio,
        current_timestamp as computed_at
    from pivoted
),

with_ttm as (
  select
    r.*,

    -- 4-Quarter Rolling TTM sums
    sum(total_revenue) over w_ttm as ttm_revenue,
    sum(operating_income) over w_ttm as ttm_operating_income,
    sum(net_income) over w_ttm as ttm_net_income,
    sum(free_cash_flow) over w_ttm as ttm_fcf,
    sum(operating_cash_flow) over w_ttm as ttm_operating_cash_flow,

    -- YoY Quarter Comparison (same quarter 1 year ago)
    lag(total_revenue, 4) over w_ticker as prev_year_revenue,
    round(
      ((total_revenue - lag(total_revenue, 4) over w_ticker) / nullif(lag(total_revenue, 4) over w_ticker, 0)) * 100,
      2
    ) as revenue_yoy_growth
  from ratios r
  window
    w_ttm as (
      partition by ticker
      order by period_end_date
      rows between 3 preceding and current row
    ),
    w_ticker as (
      partition by ticker
      order by period_end_date
    )
)

select * from with_ttm
  );
  