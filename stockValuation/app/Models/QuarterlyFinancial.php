<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class QuarterlyFinancial extends Model
{
    protected $table = 'gold.fact_quarterly_financials';
    protected $primaryKey = 'financial_sk';
    public $incrementing = false;
    protected $keyType = 'string';
    public $timestamps = false;

    protected $casts = [
        'period_end_date' => 'date',
        'filing_date' => 'date',
        'total_revenue' => 'decimal:2',
        'operating_income' => 'decimal:2',
        'net_income' => 'decimal:2',
        'gross_profit' => 'decimal:2',
        'free_cash_flow' => 'decimal:2',
        'gross_margin' => 'float',
        'operating_margin' => 'float',
        'net_margin' => 'float',
        'return_on_equity' => 'float',
        'debt_to_equity' => 'float',
        'current_ratio' => 'float',
        'fcf_conversion' => 'float',
        'computed_at' => 'datetime',
    ];

    public function company(): BelongsTo
    {
        return $this->belongsTo(Company::class, 'company_sk', 'company_sk');
    }
}
