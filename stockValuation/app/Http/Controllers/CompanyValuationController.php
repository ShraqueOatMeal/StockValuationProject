<?php

namespace App\Http\Controllers;

use App\Models\Company;
use App\Services\Valuation\DcfCalculator;
use Inertia\Inertia;
use Inertia\Response;

class CompanyValuationController
{
    public function show(string $ticker): Response
    {
        $company = Company::with([
            'latestValuation',
            'quarterlyFinancials' => function ($query) {
                $query->orderBy('period_end_date', 'asc');
            },
        ])->where('ticker', strtoupper($ticker))->firstOrFail();

        $financials = $company->quarterlyFinancials;
        $latestFinancial = $financials->last();
        $latestVal = $company->latestValuation;

        // Use Trailing Twelve Months (TTM) or last available 4 quarters of FCF
        $ttmFcf = (float) ($financials->take(-4)->sum('free_cash_flow') ?: ($latestFinancial?->free_cash_flow ?? 1e9));
        $cash = (float) ($latestFinancial?->cash_and_cash_equivalents ?? 0);
        $debt = (float) ($latestFinancial?->total_liabilities ?? 0);

        // Approximate shares outstanding from market data or use safe baseline
        $currentPrice = (float) ($latestVal?->close_price ?? 100.0);
        $sharesOutstanding = 1e9; // 1 Billion shares baseline default

        $defaults = [
            'base_fcf' => $ttmFcf > 0 ? $ttmFcf : 5e9,
            'growth_stage_1' => 0.10, // 10% annual 5-year growth
            'terminal_growth' => 0.025, // 2.5% long-run GDP rate
            'wacc' => 0.085, // 8.5% discount rate
            'cash' => $cash,
            'total_debt' => $debt,
            'shares_outstanding' => $sharesOutstanding,
            'current_price' => $currentPrice,
        ];

        $initialValuation = DcfCalculator::calculate(
            $defaults['base_fcf'],
            $defaults['growth_stage_1'],
            $defaults['terminal_growth'],
            $defaults['wacc'],
            $defaults['cash'],
            $defaults['total_debt'],
            $defaults['shares_outstanding']
        );

        $historicalStatements = $financials->map(fn($f) => [
            'period' => $f->fiscal_year . ' ' . $f->fiscal_period,
            'period_end_date' => $f->period_end_date?->format('Y-m-d'),
            'revenue' => (float) $f->total_revenue,
            'operating_income' => (float) $f->operating_income,
            'net_income' => (float) $f->net_income,
            'free_cash_flow' => (float) $f->free_cash_flow,
            'operating_cash_flow' => (float) $f->operating_cash_flow,
            'capital_expenditures' => (float) $f->capital_expenditures,
            'net_margin' => $f->net_margin ? round($f->net_margin * 100, 2) : 0,
            'roe' => $f->return_on_equity ? round($f->return_on_equity * 100, 2) : 0,
        ]);

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
            'historical' => $historicalStatements,
            'dcf_defaults' => $defaults,
            'initial_valuation' => $initialValuation,
        ]);
    }
}
