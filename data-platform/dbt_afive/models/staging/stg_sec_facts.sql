with raw_filings as (
    select
        ticker,
        cik,
        payload
    from {{ source('bronze', 'raw_sec_filings') }}
),

-- Define target GAAP taxonomy tags to extract from the raw JSONB
target_tags as (
    select unnest(array[
        -- Income Statement
        'Revenues',
        'SalesRevenueNet',
        'OperatingIncomeLoss',
        'NetIncomeLoss',
        -- Balance Sheet
        'Assets',
        'AssetsCurrent',
        'Liabilities',
        'LiabilitiesCurrent',
        'StockholdersEquity',
        'CashAndCashEquivalentsAtCarryingValue',
        -- Cash Flow Statement
        'NetCashProvidedByUsedInOperatingActivities',
        'PaymentsToAcquirePropertyPlantAndEquipment'
    ]) as tag_name
),

extracted_facts as (
    select
        f.ticker,
        f.cik,
        t.tag_name,
        jsonb_array_elements(f.payload->'facts'->'us-gaap'->t.tag_name->'units'->'USD') as unit_node
    from raw_filings f
    cross join target_tags t
    where f.payload->'facts'->'us-gaap' ? t.tag_name
),

parsed as (
    select
        ticker,
        cik,
        tag_name as gaap_tag,
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
