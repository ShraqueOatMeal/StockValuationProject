<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class DailyMarketValuation extends Model
{
    protected $table = 'gold.fact_daily_market_valuation';
    protected $primaryKey = 'valuation_sk';
    public $incrementing = false;
    protected $keyType = 'string';
    public $timestamps = false;

    protected $casts = [
        'trade_date' => 'date',
        'close_price' => 'decimal:4',
        'adj_close' => 'decimal:4',
        'volume' => 'integer',
        'dollar_volume' => 'decimal:2',
        'daily_return' => 'float',
        'sma_20' => 'decimal:4',
        'sma_50' => 'decimal:4',
        'dividend_amount' => 'decimal:4',
        'daily_dividend_yield' => 'float',
        'total_revenue' => 'decimal:2',
        'net_income' => 'decimal:2',
        'free_cash_flow' => 'decimal:2',
        'return_on_equity' => 'float',
        'calculated_at' => 'datetime',
    ];

    public function company(): BelongsTo
    {
        return $this->belongsTo(Company::class, 'company_sk', 'company_sk');
    }
}
