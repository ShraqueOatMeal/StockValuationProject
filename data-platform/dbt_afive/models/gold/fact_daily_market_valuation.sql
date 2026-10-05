with prices as (
    select * from {{ ref('silver_market_prices') }}
),

financials as (
    select * from {{ ref('fact_quarterly_financials') }}
),

-- Base-case DCF assumptions (dbt vars). With constant growth the model collapses to a
-- single multiple of the base-year cash flow:
--   sum over years 1-5 of ((1+g)/(1+r))^t  +  ((1+g)/(1+r))^5 * (1+g_term) / (r - g_term)
dcf_assumptions as (
    select
        a.*,
        (
            select sum(power((1 + a.growth_stage_1) / (1 + a.discount_rate), t))
            from generate_series(1, 5) as t
        )
        + power((1 + a.growth_stage_1) / (1 + a.discount_rate), 5)
            * (1 + a.terminal_growth) / (a.discount_rate - a.terminal_growth) as dcf_multiple
    from (
        select
            {{ var('dcf_growth_stage_1') }}::numeric as growth_stage_1,
            {{ var('dcf_terminal_growth') }}::numeric as terminal_growth,
            {{ var('dcf_discount_rate') }}::numeric as discount_rate
    ) a
),

-- Franchise model: two growth stages of five years each before the terminal value.
--   q1 = (1+g1)/(1+r), q2 = (1+g2)/(1+r)
--   sum(q1^t, t=1..5) + q1^5 * sum(q2^t, t=1..5) + q1^5 * q2^5 * (1+g_term) / (r - g_term)
franchise_assumptions as (
    select
        a.*,
        (select sum(power(a.q1, t)) from generate_series(1, 5) as t)
        + power(a.q1, 5) * (select sum(power(a.q2, t)) from generate_series(1, 5) as t)
        + power(a.q1, 5) * power(a.q2, 5)
            * (1 + a.terminal_growth) / (a.discount_rate - a.terminal_growth) as dcf_multiple
    from (
        select
            v.*,
            (1 + v.growth_stage_1) / (1 + v.discount_rate) as q1,
            (1 + v.growth_stage_2) / (1 + v.discount_rate) as q2
        from (
            select
                {{ var('dcf_franchise_growth_stage_1') }}::numeric as growth_stage_1,
                {{ var('dcf_franchise_growth_stage_2') }}::numeric as growth_stage_2,
                {{ var('dcf_franchise_terminal_growth') }}::numeric as terminal_growth,
                {{ var('dcf_franchise_discount_rate') }}::numeric as discount_rate
        ) v
    ) a
),

joined as (
    select
        -- Daily Surrogate Key
        md5(concat_ws('||', p.ticker, p.trade_date)) as valuation_sk,
        md5(p.ticker) as company_sk,
        p.ticker,
        p.trade_date,
        p.close_price,
        p.adj_close,
        p.volume,
        p.dollar_volume,
        p.daily_return,
        p.sma_20,
        p.sma_50,
        p.dividend_amount,

        -- Shares & Market Cap
        coalesce(f.shares_outstanding, 1e9) as shares_outstanding,
        round(p.close_price * coalesce(f.shares_outstanding, 1e9), 2) as market_cap,

        -- Point-in-time Financials linkage
        f.fiscal_year as latest_filed_year,
        f.fiscal_period as latest_filed_period,
        f.filing_date,
        f.total_revenue,
        f.net_income,
        f.operating_cash_flow,
        f.free_cash_flow,
        f.net_margin,
        f.return_on_equity,
        f.debt_to_equity,
        f.cash_and_cash_equivalents,
        f.total_liabilities,
        f.total_debt,
        f.cash_and_short_term_investments,
        f.non_operating_investments,
        f.revenue_yoy_growth,

        -- TTM Metrics
        f.ttm_revenue,
        f.ttm_operating_income,
        f.ttm_net_income,
        f.ttm_normalized_net_income,

        -- TTM Earnings Per Share on the latest diluted share count, so a stock split
        -- inside the trailing window can't mix pre- and post-split per-share figures
        round(f.ttm_net_income / nullif(f.diluted_shares, 0), 2) as eps_diluted_ttm,
        round(f.ttm_normalized_net_income / nullif(f.diluted_shares, 0), 2) as normalized_eps_ttm,
        f.ttm_fcf,
        f.ttm_true_owner_earnings,
        f.ttm_cash_owner_earnings,
        f.ttm_capital_expenditures,
        f.ttm_maintenance_capex,
        f.maintenance_capex_share,
        f.ttm_greenwald_maintenance_capex,
        f.greenwald_maintenance_capex_share,

        -- Enterprise Value (Market Cap + Debt - Cash); total liabilities stand in for
        -- debt only when no debt figure is available
        round(
          (p.close_price * coalesce(f.shares_outstanding, 1e9))
          + coalesce(f.total_debt, f.total_liabilities, 0)
          - coalesce(f.cash_and_cash_equivalents, 0),
          2
        ) as enterprise_value,

        -- Valuation Multiples
        round((p.close_price * coalesce(f.shares_outstanding, 1e9)) / nullif(f.ttm_net_income, 0), 2) as pe_ratio,
        round((p.close_price * coalesce(f.shares_outstanding, 1e9)) / nullif(f.ttm_normalized_net_income, 0), 2) as normalized_pe_ratio,
        round((p.close_price * coalesce(f.shares_outstanding, 1e9)) / nullif(f.ttm_fcf, 0), 2) as p_fcf_ratio,
        round(
            ((p.close_price * coalesce(f.shares_outstanding, 1e9)) + coalesce(f.total_debt, f.total_liabilities, 0) - coalesce(f.cash_and_cash_equivalents, 0)) 
            / nullif(f.ttm_revenue, 0),
            2
        ) as ev_sales_ratio,
        round(
            ((p.close_price * coalesce(f.shares_outstanding, 1e9)) + coalesce(f.total_debt, f.total_liabilities, 0) - coalesce(f.cash_and_cash_equivalents, 0)) 
            / nullif(f.ttm_operating_income, 0), 
            2
        ) as ev_ebit_ratio,

        round((p.close_price * coalesce(f.shares_outstanding, 1e9)) / nullif(f.ttm_true_owner_earnings, 0), 2) as p_owner_earnings_ratio,

        -- Fair Value: 5-year DCF of TTM True Owner Earnings plus a Gordon Growth terminal
        -- value. Owner earnings start from net income, which is already after interest,
        -- so the result is equity value: debt is not subtracted and cash is not added
        -- (interest paid and earned are both in the earnings). Long-term investments are
        -- added because their gains were stripped out of normalized earnings. NULL when
        -- owner earnings are not positive or the real share count is unknown.
        d.growth_stage_1 as dcf_growth_stage_1,
        d.terminal_growth as dcf_terminal_growth,
        d.discount_rate as dcf_discount_rate,
        case
            when f.ttm_true_owner_earnings > 0 and f.shares_outstanding > 0
            then round(
                (f.ttm_true_owner_earnings * d.dcf_multiple + coalesce(f.non_operating_investments, 0))
                / f.shares_outstanding,
                2
            )
        end as dcf_equity_value_per_share,

        -- Franchise Fair Value: 10-year, two-stage DCF of TTM Cash Owner Earnings. Operating
        -- cash flow is also after interest, so the same equity-value treatment applies.
        fr.growth_stage_1 as franchise_growth_stage_1,
        fr.growth_stage_2 as franchise_growth_stage_2,
        fr.terminal_growth as franchise_terminal_growth,
        fr.discount_rate as franchise_discount_rate,
        case
            when f.ttm_cash_owner_earnings > 0 and f.shares_outstanding > 0
            then round(
                (f.ttm_cash_owner_earnings * fr.dcf_multiple + coalesce(f.non_operating_investments, 0))
                / f.shares_outstanding,
                2
            )
        end as franchise_equity_value_per_share,

        -- Price-to-Performance indicators (Relative Yield)
        round(p.dividend_amount / nullif(p.adj_close, 0), 6) as daily_dividend_yield,
        current_timestamp as calculated_at
    from prices p
    cross join dcf_assumptions d
    cross join franchise_assumptions fr
    left join lateral (
        select *
        from financials f
        where f.ticker = p.ticker
          and f.filing_date <= p.trade_date
        order by f.filing_date desc, f.period_end_date desc
        limit 1
    ) f on true
)

select
    j.*,
    case when dcf_equity_value_per_share > 0 then dcf_equity_value_per_share end as fair_value_per_share,
    -- Margin of Safety: discount of the market price to fair value
    case
        when dcf_equity_value_per_share > 0
        then round((dcf_equity_value_per_share - close_price) / dcf_equity_value_per_share, 4)
    end as margin_of_safety,
    case when franchise_equity_value_per_share > 0 then franchise_equity_value_per_share end as franchise_fair_value_per_share,
    case
        when franchise_equity_value_per_share > 0
        then round((franchise_equity_value_per_share - close_price) / franchise_equity_value_per_share, 4)
    end as franchise_margin_of_safety
from joined j
