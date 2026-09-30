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
        max(case when gaap_tag = 'PaymentsToAcquirePropertyPlantAndEquipment' then amount end) as capital_expenditures
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
)

select * from ratios