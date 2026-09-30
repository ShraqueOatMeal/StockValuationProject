<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class UserDcfScenario extends Model
{
    protected $fillable = [
        'user_id',
        'ticker',
        'scenario_name',
        'base_fcf',
        'growth_stage_1',
        'terminal_growth',
        'wacc',
        'cash_and_equivalents',
        'total_debt',
        'shares_outstanding',
        'calculated_fair_value',
        'notes',
    ];

    protected $casts = [
        'base_fcf' => 'float',
        'growth_stage_1' => 'float',
        'terminal_growth' => 'float',
        'wacc' => 'float',
        'cash_and_equivalents' => 'float',
        'total_debt' => 'float',
        'shares_outstanding' => 'float',
        'calculated_fair_value' => 'float',
    ];

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }
}
