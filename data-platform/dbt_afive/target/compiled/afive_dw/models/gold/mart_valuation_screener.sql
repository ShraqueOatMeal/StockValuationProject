-- One row per company: its latest valuation, growth and quality figures next to its
-- industry medians. Feeds the cross-sectional screener dashboard.
with latest_valuation as (
    select distinct on (ticker) *
    from "afive_dw"."gold"."fact_daily_market_valuation"
    order by ticker, trade_date desc
),

latest_financials as (
    select distinct on (ticker) *
    from "afive_dw"."gold"."fact_quarterly_financials"
    order by ticker, period_end_date desc
)

select
    v.company_sk,
    v.ticker,
    c.company_name,
    c.industry,
    c.reporting_currency,
    v.trade_date,
    v.close_price,
    v.market_cap,
    v.enterprise_value,

    -- Valuation multiples
    v.pe_ratio,
    v.normalized_pe_ratio,
    v.p_fcf_ratio,
    v.p_owner_earnings_ratio,
    v.ev_sales_ratio,
    v.ev_ebit_ratio,

    -- Yields (inverse multiples, comparable across companies of any size)
    round(v.ttm_true_owner_earnings / nullif(v.market_cap, 0), 4) as owner_earnings_yield,
    round(v.ttm_fcf / nullif(v.market_cap, 0), 4) as fcf_yield,

    -- Growth and quality, from the latest reported quarter
    f.fiscal_year as latest_fiscal_year,
    f.fiscal_period as latest_fiscal_period,
    f.revenue_yoy_growth,
    f.gross_margin,
    f.operating_margin,
    f.net_margin,
    f.return_on_equity,
    f.asset_turnover,
    f.equity_multiplier,
    f.normalized_accruals_ratio,
    f.debt_to_equity,

    -- DCF fair values
    v.fair_value_per_share,
    v.margin_of_safety,
    v.franchise_fair_value_per_share,
    v.franchise_margin_of_safety,

    -- Industry comparison (premium is positive when the company trades above its peers).
    -- A median needs peers to mean anything, so the premium is empty below three companies.
    b.peer_count as industry_peer_count,
    b.median_pe as industry_median_pe,
    b.median_p_fcf as industry_median_p_fcf,
    b.median_ev_sales as industry_median_ev_sales,
    b.median_ev_ebit as industry_median_ev_ebit,
    case
        when b.peer_count >= 3
        then round(((v.pe_ratio - b.median_pe) / nullif(b.median_pe, 0) * 100)::numeric, 2)
    end as pe_premium_to_industry_pct,
    case
        when b.peer_count >= 3
        then round(((v.ev_sales_ratio - b.median_ev_sales) / nullif(b.median_ev_sales, 0) * 100)::numeric, 2)
    end as ev_sales_premium_to_industry_pct
from latest_valuation v
join "afive_dw"."gold"."dim_company" c on v.company_sk = c.company_sk
left join latest_financials f on v.ticker = f.ticker
left join "afive_dw"."gold"."agg_industry_benchmarks" b on c.industry = b.industry