<?php

namespace App\Services\Valuation;

class DcfCalculator
{
    /**
     * @param float $baseFcf Free cash flow in dollars
     * @param float $growthRate5Y Initial 5-year growth rate (e.g. 0.12 for 12%)
     * @param float $terminalGrowth Perpetual growth rate (e.g. 0.025 for 2.5%)
     * @param float $wacc Weighted average cost of capital (e.g. 0.09 for 9%)
     * @param float $cashAndEquivalents Cash in dollars
     * @param float $totalDebt Total debt in dollars
     * @param float $sharesOutstanding Total diluted shares count
     * @return array<string, mixed>
     */
    public static function calculate(
        float $baseFcf,
        float $growthRate5Y,
        float $terminalGrowth,
        float $wacc,
        float $cashAndEquivalents,
        float $totalDebt,
        float $sharesOutstanding
    ): array {
        if ($wacc <= $terminalGrowth) {
            $wacc = $terminalGrowth + 0.01;
        }

        $projectedFcf = [];
        $pvExplicitFcf = 0.0;
        $currentFcf = $baseFcf;

        for ($year = 1; $year <= 5; $year++) {
            $currentFcf *= (1 + $growthRate5Y);
            $discountFactor = pow(1 + $wacc, $year);
            $pvFcf = $currentFcf / $discountFactor;

            $projectedFcf[] = [
                'year' => $year,
                'fcf' => round($currentFcf, 2),
                'pv_fcf' => round($pvFcf, 2),
            ];

            $pvExplicitFcf += $pvFcf;
        }

        $terminalFcf = $currentFcf * (1 + $terminalGrowth);
        $terminalValue = $terminalFcf / ($wacc - $terminalGrowth);
        $pvTerminalValue = $terminalValue / pow(1 + $wacc, 5);

        $enterpriseValue = $pvExplicitFcf + $pvTerminalValue;
        $netDebt = $totalDebt - $cashAndEquivalents;
        $equityValue = $enterpriseValue - $netDebt;

        $fairValuePerShare = $sharesOutstanding > 0
            ? round($equityValue / $sharesOutstanding, 2)
            : 0.0;

        return [
            'pv_explicit_fcf' => round($pvExplicitFcf, 2),
            'terminal_value' => round($terminalValue, 2),
            'pv_terminal_value' => round($pvTerminalValue, 2),
            'enterprise_value' => round($enterpriseValue, 2),
            'net_debt' => round($netDebt, 2),
            'equity_value' => round($equityValue, 2),
            'fair_value_per_share' => $fairValuePerShare,
            'projections' => $projectedFcf,
        ];
    }
}
