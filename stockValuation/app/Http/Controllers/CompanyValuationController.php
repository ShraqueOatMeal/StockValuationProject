<?php

namespace App\Http\Controllers;

use App\Models\Company;
use App\Models\UserDcfScenario;
use App\Services\Valuation\DcfCalculator;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Inertia\Inertia;
use Inertia\Response;

class CompanyValuationController
{
    public function show(string $ticker): Response
    {
        $ticker = strtoupper($ticker);

        // 1. Fetch Company along with its latest daily valuation mart and quarterly financials
        $company = Company::with([
            'latestValuation', // points to gold.fact_daily_market_valuation
            'quarterlyFinancials' => fn ($query) => $query->orderBy('period_end_date', 'asc'), // points to gold.fact_quarterly_financials
        ])->where('ticker', $ticker)->firstOrFail();

        $latestVal = $company->latestValuation;
        $financials = $company->quarterlyFinancials;
        $latestFinancial = $financials->last();

        // 2. DCF Inputs: Read pre-calculated TTM FCF and balance sheet numbers directly
        $currentPrice = (float) ($latestVal?->close_price ?? 0);
        $sharesOutstanding = (float) ($latestVal?->shares_outstanding ?? 1e9);
        $baseFcf = (float) ($latestVal?->ttm_fcf ?? $latestFinancial?->free_cash_flow ?? 5e9);
        $cash = (float) ($latestVal?->cash_and_cash_equivalents ?? 0);
        $debt = (float) ($latestVal?->total_liabilities ?? 0);

        $dcfDefaults = [
            'base_fcf' => $baseFcf > 0 ? $baseFcf : 5e9,
            'growth_stage_1' => 0.10,
            'terminal_growth' => 0.025,
            'wacc' => 0.085,
            'cash' => $cash,
            'total_debt' => $debt,
            'shares_outstanding' => $sharesOutstanding,
            'current_price' => $currentPrice,
        ];

        $initialValuation = DcfCalculator::calculate(
            $dcfDefaults['base_fcf'],
            $dcfDefaults['growth_stage_1'],
            $dcfDefaults['terminal_growth'],
            $dcfDefaults['wacc'],
            $dcfDefaults['cash'],
            $dcfDefaults['total_debt'],
            $dcfDefaults['shares_outstanding']
        );

        // 3. Multiples: Pass through directly from fact_daily_market_valuation
        $multiples = [
            'market_cap' => (float) ($latestVal?->market_cap ?? 0),
            'enterprise_value' => (float) ($latestVal?->enterprise_value ?? 0),
            'ttm_revenue' => (float) ($latestVal?->ttm_revenue ?? 0),
            'ttm_net_income' => (float) ($latestVal?->ttm_net_income ?? 0),
            'ttm_fcf' => (float) ($latestVal?->ttm_fcf ?? 0),
            'pe_ratio' => $latestVal?->pe_ratio ? (float) $latestVal->pe_ratio : null,
            'p_fcf_ratio' => $latestVal?->p_fcf_ratio ? (float) $latestVal->p_fcf_ratio : null,
            'ev_sales_ratio' => $latestVal?->ev_sales_ratio ? (float) $latestVal->ev_sales_ratio : null,
            'ev_ebit_ratio' => $latestVal?->ev_ebit_ratio ? (float) $latestVal->ev_ebit_ratio : null,
        ];

        // 4. Historical Statements: Line items and margins already computed in fact_quarterly_financials
        $historical = $financials->map(fn ($f) => [
            'period' => $f->fiscal_year . ' ' . $f->fiscal_period,
            'period_end_date' => $f->period_end_date ? $f->period_end_date->format('M d, Y') : '—',
            'revenue' => (float) ($f->total_revenue ?? 0),
            'revenue_yoy' => $f->revenue_yoy_growth !== null ? (float) $f->revenue_yoy_growth : null,
            'gross_profit' => (float) ($f->gross_profit ?? 0),
            'gross_margin' => (float) ($f->gross_margin ?? 0),
            'operating_income' => (float) ($f->operating_income ?? 0),
            'operating_margin' => (float) ($f->operating_margin ?? 0),
            'net_income' => (float) ($f->net_income ?? 0),
            'net_margin' => (float) ($f->net_margin ?? 0),
            'cash_and_equivalents' => (float) ($f->cash_and_cash_equivalents ?? 0),
            'total_assets' => (float) ($f->total_assets ?? 0),
            'total_liabilities' => (float) ($f->total_liabilities ?? 0),
            'stockholders_equity' => (float) ($f->stockholders_equity ?? 0),
            'debt_to_equity' => (float) ($f->debt_to_equity ?? 0),
            'operating_cash_flow' => (float) ($f->operating_cash_flow ?? 0),
            'capital_expenditures' => (float) ($f->capital_expenditures ?? 0),
            'free_cash_flow' => (float) ($f->free_cash_flow ?? 0),
            'fcf_conversion' => $f->fcf_conversion !== null ? (float) $f->fcf_conversion : null,
        ]);

        // 5. Peer Group: Multiples read directly from peer records in fact_daily_market_valuation
        $peerCompanies = Company::with('latestValuation')
            ->where('industry', $company->industry)
            ->where('ticker', '!=', $ticker)
            ->limit(8)
            ->get();

        $peers = $peerCompanies->map(fn ($p) => [
            'ticker' => $p->ticker,
            'name' => $p->company_name,
            'price' => (float) ($p->latestValuation?->close_price ?? 0),
            'market_cap' => (float) ($p->latestValuation?->market_cap ?? 0),
            'pe' => $p->latestValuation?->pe_ratio ? (float) $p->latestValuation->pe_ratio : null,
            'p_fcf' => $p->latestValuation?->p_fcf_ratio ? (float) $p->latestValuation->p_fcf_ratio : null,
            'ev_sales' => $p->latestValuation?->ev_sales_ratio ? (float) $p->latestValuation->ev_sales_ratio : null,
            'ev_ebit' => $p->latestValuation?->ev_ebit_ratio ? (float) $p->latestValuation->ev_ebit_ratio : null,
            'net_margin' => (float) ($p->latestValuation?->net_margin ? $p->latestValuation->net_margin * 100 : 0),
        ]);

        // 6. Sector Median Benchmarks
        $benchmarks = DB::table('gold.agg_industry_benchmarks')
            ->where('industry', $company->industry)
            ->first();

        $industryBenchmarks = [
            'median_pe' => $benchmarks?->median_pe ? (float) $benchmarks->median_pe : null,
            'median_p_fcf' => $benchmarks?->median_p_fcf ? (float) $benchmarks->median_p_fcf : null,
            'median_ev_sales' => $benchmarks?->median_ev_sales ? (float) $benchmarks->median_ev_sales : null,
            'median_ev_ebit' => $benchmarks?->median_ev_ebit ? (float) $benchmarks->median_ev_ebit : null,
        ];

        // 7. Saved Scenarios (defaulted to user_id = 1 for personal analytical workstation)
        $savedScenarios = UserDcfScenario::where('user_id', 1)
            ->where('ticker', $ticker)
            ->orderBy('updated_at', 'desc')
            ->get();

        return Inertia::render('companies/show', [
            'company' => [
                'ticker' => $company->ticker,
                'name' => $company->company_name,
                'currency' => $company->reporting_currency,
                'exchange' => $company->primary_exchange,
                'industry' => $company->industry,
                'current_price' => $currentPrice,
                'daily_return' => $latestVal?->daily_return ? round($latestVal->daily_return * 100, 2) : 0,
                'sma_20' => $latestVal?->sma_20,
                'sma_50' => $latestVal?->sma_50,
            ],
            'historical' => $historical,
            'dcf_defaults' => $dcfDefaults,
            'initial_valuation' => $initialValuation,
            'saved_scenarios' => $savedScenarios,
            'multiples' => $multiples,
            'peers' => $peers,
            'industry_benchmarks' => $industryBenchmarks,
        ]);
    }

    public function storeScenario(Request $request, string $ticker): RedirectResponse
    {
        $validated = $request->validate([
            'scenario_name' => 'required|string|max:50',
            'base_fcf' => 'required|numeric',
            'growth_stage_1' => 'required|numeric',
            'terminal_growth' => 'required|numeric',
            'wacc' => 'required|numeric',
            'cash_and_equivalents' => 'required|numeric',
            'total_debt' => 'required|numeric',
            'shares_outstanding' => 'required|numeric',
            'calculated_fair_value' => 'required|numeric',
            'notes' => 'nullable|string|max:500',
        ]);

        UserDcfScenario::updateOrCreate(
            [
                'user_id' => 1,
                'ticker' => strtoupper($ticker),
                'scenario_name' => $validated['scenario_name'],
            ],
            $validated
        );

        return back()->with('success', "Scenario '{$validated['scenario_name']}' saved.");
    }
}
