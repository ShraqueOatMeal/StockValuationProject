with raw_filings as (
    select
        ticker,
        cik,
        payload
    from {{ source('bronze', 'raw_sec_filings') }}
    where form_type = 'FACTS'
),

-- Define target XBRL tags to extract from the raw JSONB.
-- Each tag lives under a taxonomy (us-gaap / dei) and a unit of measure (USD / shares).
target_tags as (
    select * from (values
        -- Income Statement
        ('us-gaap', 'Revenues', 'USD'),
        ('us-gaap', 'SalesRevenueNet', 'USD'),
        -- ASC 606 revenue tags (most filers switched to these from FY2018 onwards)
        ('us-gaap', 'RevenueFromContractWithCustomerExcludingAssessedTax', 'USD'),
        ('us-gaap', 'RevenueFromContractWithCustomerIncludingAssessedTax', 'USD'),
        ('us-gaap', 'CostOfRevenue', 'USD'),
        ('us-gaap', 'CostOfGoodsAndServicesSold', 'USD'),
        ('us-gaap', 'GrossProfit', 'USD'),
        ('us-gaap', 'OperatingIncomeLoss', 'USD'),
        ('us-gaap', 'NetIncomeLoss', 'USD'),
        ('us-gaap', 'IncomeTaxExpenseBenefit', 'USD'),
        -- Gains / losses on investment securities (excluded from normalized earnings)
        ('us-gaap', 'DebtAndEquitySecuritiesGainLoss', 'USD'),
        ('us-gaap', 'EquitySecuritiesFvNiGainLoss', 'USD'),
        ('us-gaap', 'EquitySecuritiesFvNiUnrealizedGainLoss', 'USD'),
        ('us-gaap', 'DebtSecuritiesGainLoss', 'USD'),
        ('us-gaap', 'DebtSecuritiesRealizedGainLoss', 'USD'),
        ('us-gaap', 'AvailableForSaleSecuritiesGrossRealizedGainLossNet', 'USD'),
        -- Balance Sheet
        ('us-gaap', 'Assets', 'USD'),
        ('us-gaap', 'AssetsCurrent', 'USD'),
        ('us-gaap', 'Liabilities', 'USD'),
        ('us-gaap', 'LiabilitiesCurrent', 'USD'),
        ('us-gaap', 'LongTermDebt', 'USD'),
        ('us-gaap', 'LongTermDebtNoncurrent', 'USD'),
        ('us-gaap', 'LongTermDebtCurrent', 'USD'),
        ('us-gaap', 'ShortTermBorrowings', 'USD'),
        ('us-gaap', 'StockholdersEquity', 'USD'),
        ('us-gaap', 'CashAndCashEquivalentsAtCarryingValue', 'USD'),
        ('us-gaap', 'CashCashEquivalentsAndShortTermInvestments', 'USD'),
        ('us-gaap', 'MarketableSecuritiesCurrent', 'USD'),
        ('us-gaap', 'AvailableForSaleSecuritiesDebtSecuritiesCurrent', 'USD'),
        ('us-gaap', 'AvailableForSaleSecuritiesCurrent', 'USD'),
        ('us-gaap', 'ShortTermInvestments', 'USD'),
        ('us-gaap', 'OtherLongTermInvestments', 'USD'),
        ('us-gaap', 'PropertyPlantAndEquipmentNet', 'USD'),
        ('us-gaap', 'PropertyPlantAndEquipmentAndFinanceLeaseRightOfUseAssetAfterAccumulatedDepreciationAndAmortization', 'USD'),
        -- Cash Flow Statement
        ('us-gaap', 'NetCashProvidedByUsedInOperatingActivities', 'USD'),
        ('us-gaap', 'PaymentsToAcquirePropertyPlantAndEquipment', 'USD'),
        -- Non-cash charges (inputs to owner earnings)
        ('us-gaap', 'ShareBasedCompensation', 'USD'),
        ('us-gaap', 'DepreciationDepletionAndAmortization', 'USD'),
        ('us-gaap', 'Depreciation', 'USD'),
        ('us-gaap', 'AmortizationOfIntangibleAssets', 'USD'),
        -- Share Counts
        ('us-gaap', 'CommonStockSharesOutstanding', 'shares'),
        ('us-gaap', 'WeightedAverageNumberOfDilutedSharesOutstanding', 'shares'),
        ('dei', 'EntityCommonStockSharesOutstanding', 'shares')
    ) as t (taxonomy, tag_name, unit)
),

extracted_facts as (
    select
        f.ticker,
        f.cik,
        t.tag_name,
        t.unit,
        jsonb_array_elements(f.payload->'facts'->t.taxonomy->t.tag_name->'units'->t.unit) as unit_node
    from raw_filings f
    cross join target_tags t
    where jsonb_typeof(f.payload->'facts'->t.taxonomy->t.tag_name->'units'->t.unit) = 'array'
),

parsed as (
    select
        ticker,
        cik,
        tag_name as gaap_tag,
        unit,
        unit_node->>'form' as form_type,
        (unit_node->>'fy')::int as fiscal_year,
        upper(unit_node->>'fp') as fiscal_period,
        (unit_node->>'filed')::date as filed_date,
        (unit_node->>'start')::date as period_start_date,
        (unit_node->>'end')::date as period_end_date,
        (unit_node->>'val')::numeric(20, 2) as amount,
        unit_node->>'accn' as accession_number
    from extracted_facts
    where unit_node->>'val' is not null
      and unit_node->>'fy' is not null
      and unit_node->>'fp' in ('Q1', 'Q2', 'Q3', 'FY')
)

select distinct * from parsed
