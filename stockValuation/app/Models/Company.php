<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Database\Eloquent\Relations\HasOne;

class Company extends Model
{
    // Explicitly target the Gold schema
    protected $table = 'gold.dim_company';
    protected $primaryKey = 'company_sk';
    public $incrementing = false;
    protected $keyType = 'string';
    public $timestamps = false;

    protected $fillable = [
        'company_sk',
        'ticker',
        'cik',
        'company_name',
        'reporting_currency',
        'primary_exchange',
        'industry',
        'is_active',
    ];

    protected $casts = [
        'is_active' => 'boolean',
        'created_at' => 'datetime',
    ];

    public function quarterlyFinancials(): HasMany
    {
        return $this->hasMany(QuarterlyFinancial::class, 'company_sk', 'company_sk')
                    ->orderBy('period_end_date', 'desc');
    }

    public function dailyValuations(): HasMany
    {
        return $this->hasMany(DailyMarketValuation::class, 'company_sk', 'company_sk')
                    ->orderBy('trade_date', 'desc');
    }

    public function latestValuation(): HasOne
    {
        return $this->hasOne(DailyMarketValuation::class, 'company_sk', 'company_sk')
                    ->latestOfMany('trade_date');
    }
}
