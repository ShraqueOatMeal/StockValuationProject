with scd2 as (
    select * from {{ ref('silver_financial_statements_scd2') }}
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
        ('IncomeTaxExpenseBenefit', 'income_tax_expense', 1),
        ('DebtAndEquitySecuritiesGainLoss', 'investment_gains_total', 1),
        ('EquitySecuritiesFvNiGainLoss', 'investment_gains_equity', 1),
        ('EquitySecuritiesFvNiUnrealizedGainLoss', 'investment_gains_equity', 2),
        ('DebtSecuritiesGainLoss', 'investment_gains_debt', 1),
        ('DebtSecuritiesRealizedGainLoss', 'investment_gains_debt', 2),
        ('AvailableForSaleSecuritiesGrossRealizedGainLossNet', 'investment_gains_debt', 3),
        ('NetCashProvidedByUsedInOperatingActivities', 'cfo', 1),
        ('PaymentsToAcquirePropertyPlantAndEquipment', 'capex', 1),
        ('ShareBasedCompensation', 'stock_based_compensation', 1),
        ('DepreciationDepletionAndAmortization', 'depreciation_and_amortization', 1),
        ('Depreciation', 'depreciation', 1),
        ('AmortizationOfIntangibleAssets', 'amortization', 1),
        ('Assets', 'total_assets', 1),
        ('AssetsCurrent', 'current_assets', 1),
        ('Liabilities', 'total_liabilities', 1),
        ('LiabilitiesCurrent', 'current_liabilities', 1),
        ('LongTermDebt', 'long_term_debt', 1),
        ('LongTermDebtNoncurrent', 'long_term_debt_noncurrent', 1),
        ('LongTermDebtCurrent', 'long_term_debt_current', 1),
        ('ShortTermBorrowings', 'short_term_borrowings', 1),
        ('StockholdersEquity', 'stockholders_equity', 1),
        ('CashAndCashEquivalentsAtCarryingValue', 'cash_and_cash_equivalents', 1),
        ('CashCashEquivalentsAndShortTermInvestments', 'cash_and_short_term_investments', 1),
        ('MarketableSecuritiesCurrent', 'short_term_investments', 1),
        ('AvailableForSaleSecuritiesDebtSecuritiesCurrent', 'short_term_investments', 2),
        ('AvailableForSaleSecuritiesCurrent', 'short_term_investments', 3),
        ('ShortTermInvestments', 'short_term_investments', 4),
        ('OtherLongTermInvestments', 'non_operating_investments', 1),
        ('PropertyPlantAndEquipmentNet', 'ppe_net', 1),
        ('PropertyPlantAndEquipmentAndFinanceLeaseRightOfUseAssetAfterAccumulatedDepreciationAndAmortization', 'ppe_net', 2),
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
latest_facts as (
    select distinct on (ticker, metric, period_end_date, period_start_date)
        ticker,
        cik,
        metric,
        period_start_date,
        period_end_date,
        amount,
        valid_from as filed_date,
        -- Duration in days (NULL for balance sheet instants)
        period_end_date - period_start_date as duration_days
    from mapped
    where is_current = true
    order by ticker, metric, period_end_date, period_start_date, valid_from desc, tag_priority
),

-- Share counts are put on today's share basis. A filing made after a split already shows
-- adjusted figures, including its prior-period comparatives, so a count only needs the
-- splits that took effect after the filing it was last reported in.
current_facts as (
    select
        f.ticker,
        f.cik,
        f.metric,
        f.period_start_date,
        f.period_end_date,
        case
            when f.metric in ('shares_balance_sheet', 'shares_cover_page', 'shares_diluted_avg')
            then f.amount * coalesce(s.later_split_factor, 1)
            else f.amount
        end as amount,
        f.duration_days
    from latest_facts f
    left join lateral (
        select exp(sum(ln(sp.split_ratio)))::numeric as later_split_factor
        from {{ ref('stg_stock_splits') }} sp
        where sp.ticker = f.ticker
          and sp.split_date > f.filed_date
    ) s on true
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
      -- A weighted average share count is not additive, so it can't be derived this way
      and c.metric <> 'shares_diluted_avg'
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
        max(amount) filter (where metric = 'income_tax_expense') as income_tax_expense,
        -- Pre-tax gains (losses) on investment securities: the combined debt + equity
        -- figure where reported, otherwise the sum of whichever parts are. NULL when
        -- the filing reports none.
        coalesce(
            max(amount) filter (where metric = 'investment_gains_total'),
            case
                when count(*) filter (where metric in ('investment_gains_equity', 'investment_gains_debt')) > 0
                then coalesce(max(amount) filter (where metric = 'investment_gains_equity'), 0)
                    + coalesce(max(amount) filter (where metric = 'investment_gains_debt'), 0)
            end
        ) as investment_gains,
        max(amount) filter (where metric = 'cfo') as operating_cash_flow,
        max(amount) filter (where metric = 'capex') as capital_expenditures,
        max(amount) filter (where metric = 'stock_based_compensation') as stock_based_compensation,
        -- D&A: combined tag where reported, otherwise depreciation + amortization of intangibles
        coalesce(
            max(amount) filter (where metric = 'depreciation_and_amortization'),
            max(amount) filter (where metric = 'depreciation')
                + coalesce(max(amount) filter (where metric = 'amortization'), 0)
        ) as depreciation_and_amortization,
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
        -- Interest-bearing debt: non-current + current long-term debt where split out,
        -- otherwise the combined long-term debt tag, plus short-term borrowings
        coalesce(
            max(amount) filter (where metric = 'long_term_debt_noncurrent')
                + coalesce(max(amount) filter (where metric = 'long_term_debt_current'), 0),
            max(amount) filter (where metric = 'long_term_debt')
        ) + coalesce(max(amount) filter (where metric = 'short_term_borrowings'), 0) as total_debt,
        max(amount) filter (where metric = 'stockholders_equity') as stockholders_equity,
        max(amount) filter (where metric = 'cash_and_cash_equivalents') as cash_and_cash_equivalents,
        -- Cash plus marketable securities: the combined tag, else cash + short-term investments
        coalesce(
            max(amount) filter (where metric = 'cash_and_short_term_investments'),
            max(amount) filter (where metric = 'cash_and_cash_equivalents')
                + max(amount) filter (where metric = 'short_term_investments')
        ) as cash_and_short_term_investments,
        max(amount) filter (where metric = 'ppe_net') as property_plant_equipment_net,
        max(amount) filter (where metric = 'non_operating_investments') as non_operating_investments,
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

-- Yahoo Finance fundamentals: fallback for companies that do not file with the SEC and
-- for line items missing from the XBRL data. Quarterly figures are already discrete.
yf_quarterly as (
    select
        ticker,
        period_end_date,
        max(amount) filter (where line_item = 'Total Revenue') as total_revenue,
        max(amount) filter (where line_item = 'Gross Profit') as gross_profit,
        -- Banks and insurers report no operating income line; pre-tax profit is their
        -- equivalent, since interest is part of operations
        coalesce(
            max(amount) filter (where line_item = 'Operating Income'),
            max(amount) filter (where line_item = 'Pretax Income')
        ) as operating_income,
        max(amount) filter (where line_item = 'Net Income') as net_income,
        max(amount) filter (where line_item = 'Tax Provision') as income_tax_expense,
        -- Reported on the cash flow statement as an adjustment, so a gain is negative
        -max(amount) filter (where line_item = 'Gain Loss On Investment Securities') as investment_gains,
        max(amount) filter (where line_item = 'Total Assets') as total_assets,
        max(amount) filter (where line_item = 'Current Assets') as current_assets,
        max(amount) filter (where line_item = 'Total Liabilities Net Minority Interest') as total_liabilities,
        max(amount) filter (where line_item = 'Current Liabilities') as current_liabilities,
        max(amount) filter (where line_item = 'Total Debt') as total_debt,
        max(amount) filter (where line_item = 'Stockholders Equity') as stockholders_equity,
        max(amount) filter (where line_item = 'Cash And Cash Equivalents') as cash_and_cash_equivalents,
        max(amount) filter (where line_item = 'Cash Cash Equivalents And Short Term Investments') as cash_and_short_term_investments,
        max(amount) filter (where line_item = 'Operating Cash Flow') as operating_cash_flow,
        abs(max(amount) filter (where line_item = 'Capital Expenditure')) as capital_expenditures,
        max(amount) filter (where line_item = 'Stock Based Compensation') as stock_based_compensation,
        coalesce(
            max(amount) filter (where line_item = 'Depreciation And Amortization'),
            max(amount) filter (where line_item = 'Depreciation Amortization Depletion')
        ) as depreciation_and_amortization,
        max(amount) filter (where line_item = 'Net PPE') as property_plant_equipment_net,
        max(amount) filter (where line_item = 'Other Investments') as non_operating_investments,
        max(amount) filter (where line_item = 'Ordinary Shares Number') as shares_outstanding,
        max(amount) filter (where line_item = 'Diluted Average Shares') as diluted_shares
    from {{ ref('stg_yf_fundamentals') }}
    where frequency = 'quarterly'
    group by ticker, period_end_date
),

-- Full-year D&A, for fiscal years whose quarters cannot be read directly. A 10-K can
-- report the annual figure even when the 10-Qs never tagged the quarterly ones.
annual_depreciation as (
    select distinct on (ticker, period_end_date)
        ticker,
        period_end_date,
        depreciation_and_amortization,
        source
    from (
        select
            ticker,
            period_end_date,
            coalesce(
                max(amount) filter (where metric = 'depreciation_and_amortization'),
                max(amount) filter (where metric = 'depreciation')
                    + coalesce(max(amount) filter (where metric = 'amortization'), 0)
            ) as depreciation_and_amortization,
            'sec_annual' as source,
            1 as source_priority
        from flows
        where duration_days between 350 and 380
        group by ticker, period_end_date

        union all

        select
            ticker,
            period_end_date,
            coalesce(
                max(amount) filter (where line_item = 'Depreciation And Amortization'),
                max(amount) filter (where line_item = 'Depreciation Amortization Depletion')
            ) as depreciation_and_amortization,
            'yfinance_annual' as source,
            2 as source_priority
        from {{ ref('stg_yf_fundamentals') }}
        where frequency = 'annual'
        group by ticker, period_end_date
    ) a
    where depreciation_and_amortization is not null
    order by ticker, period_end_date, source_priority
),

-- Quarter spine: one row per period end that has income statement / cash flow data.
-- SEC quarters come first; Yahoo Finance adds quarters the SEC data does not cover.
quarter_spine as (
    select ticker, period_end_date, 'sec' as data_source
    from flows_pivoted

    union all

    select y.ticker, y.period_end_date, 'yfinance' as data_source
    from yf_quarterly y
    where coalesce(y.net_income, y.total_revenue) is not null
      and not exists (
          select 1
          from flows_pivoted f
          where f.ticker = y.ticker
            and abs(f.period_end_date - y.period_end_date) <= 20
      )
),

quarter_inputs as (
    select
        s.ticker,
        ff.cik,
        s.data_source,
        -- Label by the calendar quarter of the period end instead of the filing header's
        -- fy/fp, which describe the filing rather than the period the fact covers.
        extract(year from s.period_end_date)::int as fiscal_year,
        'Q' || extract(quarter from s.period_end_date)::text as fiscal_period,
        s.period_end_date,
        -- Yahoo Finance carries no filing date; assume results are public 60 days after
        -- the period end so the point-in-time join downstream stays conservative
        coalesce(ff.filing_date, s.period_end_date + 60) as filing_date,
        ff.accession_number,
        coalesce(f.total_revenue, y.total_revenue) as total_revenue,
        coalesce(f.reported_gross_profit, f.total_revenue - f.cost_of_revenue, y.gross_profit) as gross_profit,
        coalesce(f.operating_income, y.operating_income) as operating_income,
        coalesce(f.net_income, y.net_income) as net_income,
        coalesce(f.income_tax_expense, y.income_tax_expense) as income_tax_expense,
        -- SEC figure first, then Yahoo Finance; zero when neither reports any
        coalesce(f.investment_gains, y.investment_gains, 0) as investment_gains,
        coalesce(i.total_assets, y.total_assets) as total_assets,
        coalesce(i.current_assets, y.current_assets) as current_assets,
        coalesce(i.total_liabilities, y.total_liabilities) as total_liabilities,
        coalesce(i.current_liabilities, y.current_liabilities) as current_liabilities,
        -- Yahoo Finance first here: its total includes lease obligations and is tagged
        -- consistently, whereas XBRL debt tags vary from filer to filer
        coalesce(y.total_debt, i.total_debt) as total_debt,
        coalesce(i.stockholders_equity, y.stockholders_equity) as stockholders_equity,
        coalesce(i.cash_and_cash_equivalents, y.cash_and_cash_equivalents) as cash_and_cash_equivalents,
        -- Falls back to plain cash when no short-term investments are reported
        coalesce(
            i.cash_and_short_term_investments,
            y.cash_and_short_term_investments,
            i.cash_and_cash_equivalents,
            y.cash_and_cash_equivalents
        ) as cash_and_short_term_investments,
        coalesce(f.operating_cash_flow, y.operating_cash_flow) as operating_cash_flow,
        coalesce(f.capital_expenditures, y.capital_expenditures) as capital_expenditures,
        coalesce(f.stock_based_compensation, y.stock_based_compensation) as stock_based_compensation,
        -- Long-term investment holdings (mostly non-marketable equity stakes). Their gains
        -- are stripped from normalized earnings, so their value is added back in the DCF.
        coalesce(i.non_operating_investments, y.non_operating_investments, 0) as non_operating_investments,
        -- Reported D&A by source; combined in order of preference in the next step
        f.depreciation_and_amortization as sec_depreciation_and_amortization,
        y.depreciation_and_amortization as yf_depreciation_and_amortization,
        coalesce(i.property_plant_equipment_net, y.property_plant_equipment_net) as property_plant_equipment_net,
        -- Net PP&E at the previous quarter end (NULL when the prior quarter is missing)
        case
            when s.period_end_date - lag(s.period_end_date) over w_ticker <= 105
            then lag(coalesce(i.property_plant_equipment_net, y.property_plant_equipment_net)) over w_ticker
        end as prev_property_plant_equipment_net,
        -- Shares: balance sheet count, then the 10-Q/10-K cover page count (dated a few
        -- weeks after the period end), then the diluted weighted average for the quarter
        coalesce(i.shares_balance_sheet, cp.amount, f.shares_diluted_avg, y.shares_outstanding) as shares_outstanding,
        -- Diluted share count for per-share earnings: the quarter's diluted weighted
        -- average, else the period-end share count (Q4 only reports a full-year average)
        coalesce(f.shares_diluted_avg, i.shares_balance_sheet, cp.amount, y.diluted_shares, y.shares_outstanding) as diluted_shares
    from quarter_spine s
    left join flows_pivoted f
        on s.ticker = f.ticker
        and s.period_end_date = f.period_end_date
    left join yf_quarterly y
        on s.ticker = y.ticker
        and s.period_end_date = y.period_end_date
    left join instants_pivoted i
        on s.ticker = i.ticker
        and s.period_end_date = i.period_end_date
    left join first_filings ff
        on s.ticker = ff.ticker
        and s.period_end_date = ff.period_end_date
    left join lateral (
        select c.amount
        from instants c
        where c.metric = 'shares_cover_page'
          and c.ticker = s.ticker
          and c.period_end_date > s.period_end_date
          and c.period_end_date <= s.period_end_date + 100
        order by c.period_end_date
        limit 1
    ) cp on true
    window w_ticker as (partition by s.ticker order by s.period_end_date)
),

-- Share of a fiscal year's reported D&A that belongs to each quarter lacking its own
-- figure: the annual total, less the quarters that are reported, spread evenly over the rest
annual_depreciation_split as (
    select
        q.ticker,
        q.period_end_date,
        a.source,
        case
            when count(*) over w_year = 4
            then (a.depreciation_and_amortization
                    - coalesce(sum(coalesce(q.sec_depreciation_and_amortization, q.yf_depreciation_and_amortization)) over w_year, 0))
                / nullif(count(*) filter (where coalesce(q.sec_depreciation_and_amortization, q.yf_depreciation_and_amortization) is null) over w_year, 0)
            else a.depreciation_and_amortization / 4
        end as annual_split
    from quarter_inputs q
    join annual_depreciation a
        on q.ticker = a.ticker
        and q.period_end_date > a.period_end_date - 360
        and q.period_end_date <= a.period_end_date
    window w_year as (partition by q.ticker, a.period_end_date)
),

-- Depreciation for the owner earnings calculation. Reported D&A always comes first,
-- whichever source has it; the estimate is only a last resort:
--   1. Quarterly D&A from the SEC filing
--   2. Quarterly D&A from Yahoo Finance
--   3. Annual D&A (SEC, then Yahoo Finance) allocated to the quarters lacking their own
--   4. An estimate from the net PP&E roll-forward
quarters as (
    select
        q.*,
        coalesce(q.sec_depreciation_and_amortization, q.yf_depreciation_and_amortization) as depreciation_and_amortization,
        case
            when q.sec_depreciation_and_amortization is not null then 'sec'
            when q.yf_depreciation_and_amortization is not null then 'yfinance'
            when a.annual_split is not null then a.source
            when e.ppe_rollforward is not null then 'ppe_rollforward'
        end as depreciation_source,
        -- Only the PP&E roll-forward is an estimate; every other source is reported D&A
        d.depreciation_basis is not null
            and coalesce(q.sec_depreciation_and_amortization, q.yf_depreciation_and_amortization, a.annual_split) is null
            as maintenance_capex_is_estimated,
        -- Maintenance CapEx: spend needed to keep the existing asset base running, proxied
        -- by depreciation and capped at actual CapEx. NULL when depreciation is unknown.
        case
            when d.depreciation_basis is not null
            then least(coalesce(q.capital_expenditures, 0), d.depreciation_basis)
        end as maintenance_capex,
        -- Depreciation consumed by maintenance CapEx nets out of owner earnings; only the
        -- excess of depreciation over CapEx is added back
        d.depreciation_basis
    from quarter_inputs q
    left join annual_depreciation_split a
        on q.ticker = a.ticker
        and q.period_end_date = a.period_end_date
        and a.annual_split > 0
    cross join lateral (
        -- Opening net PP&E + CapEx - closing net PP&E. It ignores acquisitions, disposals
        -- and non-cash additions, so it tends to understate reported depreciation.
        select
            case
                when q.prev_property_plant_equipment_net + q.capital_expenditures - q.property_plant_equipment_net > 0
                then q.prev_property_plant_equipment_net + q.capital_expenditures - q.property_plant_equipment_net
            end as ppe_rollforward
    ) e
    cross join lateral (
        select coalesce(
            q.sec_depreciation_and_amortization,
            q.yf_depreciation_and_amortization,
            a.annual_split,
            e.ppe_rollforward
        ) as depreciation_basis
    ) d
),

-- Normalized earnings: GAAP net income with after-tax gains and losses on investment
-- securities removed. Those swing net income with market prices without reflecting the
-- earning power of the business; interest and other non-operating income stay in.
normalized as (
    select
        q.*,
        q.net_income - q.investment_gains * (1 - t.effective_tax_rate) as normalized_net_income
    from (
        select
            q.*,
            sum(q.income_tax_expense) over w_ttm as ttm_income_tax_expense,
            sum(q.net_income + q.income_tax_expense) over w_ttm as ttm_pretax_income
        from quarters q
        window w_ttm as (
            partition by q.ticker
            order by q.period_end_date
            range between interval '300 days' preceding and current row
        )
    ) q
    cross join lateral (
        -- Trailing effective tax rate, kept within 0-35% so one-off tax items don't
        -- distort it; the 21% US statutory rate applies when pre-tax income is not positive
        select
            case
                when q.ttm_pretax_income > 0
                then least(greatest(q.ttm_income_tax_expense / q.ttm_pretax_income, 0), 0.35)
                else 0.21
            end as effective_tax_rate
    ) t
),

ratios as (
  select
    -- Surrogate Key
    md5(concat_ws('||', ticker, fiscal_year, fiscal_period)) as financial_sk,
    md5(ticker) as company_sk,
    ticker,
    data_source,
    fiscal_year,
    fiscal_period,
    period_end_date,
    filing_date,
    accession_number,
    total_revenue,
    gross_profit,
    operating_income,
    net_income,
    normalized_net_income,
    investment_gains,
    total_assets,
    current_assets,
    total_liabilities,
    current_liabilities,
    total_debt,
    stockholders_equity,
    cash_and_cash_equivalents,
    cash_and_short_term_investments,
    non_operating_investments,
    operating_cash_flow,
    capital_expenditures,
    stock_based_compensation,
    depreciation_and_amortization,
    property_plant_equipment_net,
    maintenance_capex,
    depreciation_source,
    maintenance_capex_is_estimated,
    shares_outstanding,
    diluted_shares,

    -- Earnings Per Share: GAAP diluted, and normalized (excluding investment gains)
    round(net_income / nullif(diluted_shares, 0), 2) as eps_diluted,
    round(normalized_net_income / nullif(diluted_shares, 0), 2) as normalized_eps,

    -- Derived Free Cash Flow
    (operating_cash_flow - coalesce(capital_expenditures, 0)) as free_cash_flow,

    -- True Owner Earnings (Buffett, 1986), on normalized earnings so that one-off gains
    -- don't flow into the valuation: net income, plus depreciation & amortization,
    -- less maintenance CapEx. Growth CapEx is discretionary and therefore not deducted.
    -- Without reported D&A, depreciation is estimated from the net PP&E roll-forward; if
    -- that is not possible either, the add-back and its proxy cancel, leaving net income.
    (coalesce(normalized_net_income, net_income) + coalesce(depreciation_basis - maintenance_capex, 0)) as true_owner_earnings,

    -- Cash Owner Earnings: operating cash flow less maintenance CapEx. Unlike True Owner
    -- Earnings it keeps working capital movements and adds back stock-based compensation.
    -- All CapEx counts as maintenance when depreciation is unknown.
    (operating_cash_flow - coalesce(maintenance_capex, capital_expenditures, 0)) as cash_owner_earnings,

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

    -- DuPont decomposition of quarterly ROE: net margin x asset turnover x equity multiplier
    round(total_revenue / nullif(total_assets, 0), 4) as asset_turnover,
    round(total_assets / nullif(stockholders_equity, 0), 4) as equity_multiplier,

    -- Sloan accruals ratio: earnings not backed by operating cash flow, scaled by assets.
    -- The normalized variant leaves out investment gains, which are non-cash by nature
    -- and would otherwise read as aggressive accounting.
    round((net_income - operating_cash_flow) / nullif(total_assets, 0), 4) as accruals_ratio,
    round((normalized_net_income - operating_cash_flow) / nullif(total_assets, 0), 4) as normalized_accruals_ratio,
    current_timestamp as computed_at
  from normalized
),

with_ttm as (
  select
    r.*,

    -- 4-Quarter Rolling TTM sums (NULL unless all four quarters are present)
    case when count(r.total_revenue) over w_ttm = 4 then sum(r.total_revenue) over w_ttm end as ttm_revenue,
    case when count(r.operating_income) over w_ttm = 4 then sum(r.operating_income) over w_ttm end as ttm_operating_income,
    case when count(r.net_income) over w_ttm = 4 then sum(r.net_income) over w_ttm end as ttm_net_income,
    case when count(r.normalized_net_income) over w_ttm = 4 then sum(r.normalized_net_income) over w_ttm end as ttm_normalized_net_income,
    case when count(r.free_cash_flow) over w_ttm = 4 then sum(r.free_cash_flow) over w_ttm end as ttm_fcf,
    case when count(r.operating_cash_flow) over w_ttm = 4 then sum(r.operating_cash_flow) over w_ttm end as ttm_operating_cash_flow,
    case when count(r.true_owner_earnings) over w_ttm = 4 then sum(r.true_owner_earnings) over w_ttm end as ttm_true_owner_earnings,
    case when count(r.cash_owner_earnings) over w_ttm = 4 then sum(r.cash_owner_earnings) over w_ttm end as ttm_cash_owner_earnings,
    case when count(r.capital_expenditures) over w_ttm = 4 then sum(r.capital_expenditures) over w_ttm end as ttm_capital_expenditures,
    case when count(r.maintenance_capex) over w_ttm = 4 then sum(r.maintenance_capex) over w_ttm end as ttm_maintenance_capex,
    -- Share of trailing CapEx treated as maintenance (the rest is growth CapEx)
    case
        when count(r.maintenance_capex) over w_ttm = 4 and count(r.capital_expenditures) over w_ttm = 4
        then round(sum(r.maintenance_capex) over w_ttm / nullif(sum(r.capital_expenditures) over w_ttm, 0), 4)
    end as maintenance_capex_share,

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
),

-- Greenwald's estimate of maintenance CapEx, independent of depreciation:
--   growth CapEx      = (net PP&E / TTM revenue) x (TTM revenue - TTM revenue a year ago)
--   maintenance CapEx = TTM CapEx - growth CapEx, kept between zero and total CapEx
-- It runs high when capacity is built ahead of demand, since PP&E arrives before the sales.
with_greenwald as (
  select
    t.*,
    g.greenwald_maintenance_capex as ttm_greenwald_maintenance_capex,
    round(g.greenwald_maintenance_capex / nullif(t.ttm_capital_expenditures, 0), 4) as greenwald_maintenance_capex_share
  from with_ttm t
  left join with_ttm py
    on t.ticker = py.ticker
    and py.fiscal_year = t.fiscal_year - 1
    and py.fiscal_period = t.fiscal_period
  cross join lateral (
    select
      -- NULL unless PP&E, CapEx and both years of trailing revenue are all available
      case
        when t.property_plant_equipment_net is not null
         and t.ttm_capital_expenditures is not null
         and t.ttm_revenue > 0
         and py.ttm_revenue is not null
        then least(
          greatest(
            t.ttm_capital_expenditures
              - greatest(t.property_plant_equipment_net / t.ttm_revenue * (t.ttm_revenue - py.ttm_revenue), 0),
            0
          ),
          t.ttm_capital_expenditures
        )
      end as greenwald_maintenance_capex
  ) g
)

select * from with_greenwald
