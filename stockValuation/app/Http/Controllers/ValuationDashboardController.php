<?php

namespace App\Http\Controllers;

use App\Models\Company;
use Inertia\Inertia;
use Inertia\Response;

class ValuationDashboardController extends Controller
{
    public function index(): Response
    {
        $companies = Company::with(['latestValuation'])
            ->where('is_active', true)
            ->get()
            ->map(function ($company) {
                $val = $company->latestValuation;
                return [
                    'ticker' => $company->ticker,
                    'name' => $company->company_name,
                    'currency' => $company->reporting_currency,
                    'exchange' => $company->primary_exchange,
                    'industry' => $company->industry,
                    'latest_trade_date' => $val?->trade_date?->format('Y-m-d'),
                    'close_price' => $val?->close_price,
                    'daily_return' => $val?->daily_return ? round($val->daily_return * 100, 2) : 0,
                    'sma_20' => $val?->sma_20,
                    'sma_50' => $val?->sma_50,
                    'free_cash_flow' => $val?->free_cash_flow,
                    'net_margin' => $val?->net_margin ? round($val->net_margin * 100, 2) : null,
                    'roe' => $val?->return_on_equity ? round($val->return_on_equity * 100, 2) : null,
                ];
            });

        return Inertia::render('Dashboard', [
            'watchlist' => $companies,
        ]);
    }
}
