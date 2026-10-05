import { useState, useMemo } from 'react';
import AppLayout from '@/layouts/app-layout';
import { Head, Link, router } from '@inertiajs/react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Slider } from '@/components/ui/slider';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Separator } from '@/components/ui/separator';
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Bookmark, Check, Save } from 'lucide-react';
import { FinancialStatementsTable } from '@/components/valuation/financial-statements-table'
import {
    ResponsiveContainer,
    ComposedChart,
    Bar,
    Line,
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip,
    Legend,
} from 'recharts';

interface StatementRecord {
    period: string;
    period_end_date: string;
    revenue: number;
    operating_income: number;
    net_income: number;
    free_cash_flow: number;
    operating_cash_flow: number;
    capital_expenditures: number;
    net_margin: number;
    roe: number;
}

type DcfModelKey = 'conservative' | 'franchise';

interface DcfModel {
    base_owner_earnings: number;
    // Base figure with maintenance CapEx added back; null when the what-if is unavailable
    base_before_maintenance_capex: number | null;
    growth_stage_1: number;
    growth_stage_2: number;
    stage_2_years: number;
    terminal_growth: number;
    wacc: number;
    non_operating_investments: number;
    shares_outstanding: number;
    fair_value_per_share: number | null;
}

const DCF_MODEL_COPY: Record<DcfModelKey, { label: string; baseLabel: string; description: string }> = {
    conservative: {
        label: 'Conservative',
        baseLabel: 'Base True Owner Earnings, TTM ($B)',
        description:
            'Stress-test case. Discounts True Owner Earnings (normalized net income plus depreciation & amortization, less maintenance CapEx) over 5 years of growth. Assumes maintenance CapEx is roughly equal to D&A.',
    },
    franchise: {
        label: 'Franchise',
        baseLabel: 'Base Cash Owner Earnings, TTM ($B)',
        description:
            'Compounder case. Discounts Cash Owner Earnings (operating cash flow less maintenance CapEx) over 10 years of growth in two stages. Assumes maintenance CapEx is roughly equal to D&A.',
    },
};

interface MultiplesData {
    market_cap: number;
    enterprise_value: number;
    ttm_revenue: number;
    ttm_net_income: number;
    ttm_fcf: number;
    ttm_true_owner_earnings: number;
    p_owner_earnings_ratio: number | null;
    fair_value_per_share: number | null;
    margin_of_safety: number | null;
    pe_ratio: number | null;
    eps_diluted_ttm: number | null;
    normalized_eps_ttm: number | null;
    normalized_pe_ratio: number | null;
    p_fcf_ratio: number | null;
    ev_sales_ratio: number | null;
    ev_ebit_ratio: number | null;
}

interface PeerData {
    ticker: string;
    name: string;
    price: number;
    market_cap: number;
    pe: number | null;
    p_fcf: number | null;
    ev_sales: number | null;
    ev_ebit: number | null;
    net_margin: number;
}

interface IndustryBenchmarks {
    median_pe: number | null;
    median_p_fcf: number | null;
    median_ev_sales: number | null;
    median_ev_ebit: number | null;
}

interface Props {
    company: {
        ticker: string;
        name: string;
        currency: string;
        exchange: string;
        industry: string;
        current_price: number;
        daily_return: number;
        sma_20: number | string | null;
        sma_50: number | string | null;
    };
    historical: StatementRecord[];
    dcf_models: Record<DcfModelKey, DcfModel>;
    maintenance_capex: { ttm_capex: number | null; default_share: number | null; greenwald_share: number | null };
    saved_scenarios: SavedScenario[];
    multiples: MultiplesData;
    peers?:PeerData[];
    industry_benchmarks?:IndustryBenchmarks;
}

interface SensitivityPoint{
    wacc: number;
    terminalGrowth: number;
    fairValue: number;
    marginOfSafety: number;
}

interface DcfInputs {
    base: number;
    growthStage1: number;
    growthStage2: number;
    stage2Years: number;
    terminalGrowth: number;
    discountRate: number;
    investments: number;
    shares: number;
}

// Shared by the live valuation and the sensitivity matrix: 5 years at the stage-1 growth
// rate, optionally followed by a second stage, then a Gordon Growth terminal value.
// The cash flows are after interest, so their present value is equity value; long-term
// investments excluded from those cash flows are added on top.
function runDcf({ base, growthStage1, growthStage2, stage2Years, terminalGrowth, discountRate, investments, shares }: DcfInputs) {
    const years = 5 + stage2Years;
    let pvExplicit = 0;
    let running = base;
    const projections = [];

    for (let year = 1; year <= years; year++) {
        running *= 1 + (year <= 5 ? growthStage1 : growthStage2);
        const pv = running / Math.pow(1 + discountRate, year);
        pvExplicit += pv;
        projections.push({ year: `Year ${year}`, fcf: running / 1e9, pv_fcf: pv / 1e9 });
    }

    const terminalValue = (running * (1 + terminalGrowth)) / (discountRate - terminalGrowth);
    const pvTerminalValue = terminalValue / Math.pow(1 + discountRate, years);
    const earningsValue = pvExplicit + pvTerminalValue;
    const equityValue = earningsValue + investments;
    const fairValue = shares > 0 ? equityValue / shares : 0;

    return { pvExplicit, terminalValue, pvTerminalValue, earningsValue, equityValue, fairValue, projections };
}

function generateSensitivityMatrix(
    inputs: Omit<DcfInputs, 'terminalGrowth' | 'discountRate'>,
    baseWacc: number,
    baseTerminalGrowth: number,
    currentPrice: number
): { waccSteps: number[]; growthSteps: number[]; matrix: SensitivityPoint[][] } {
    // 5 WACC steps centered around current WACC (-2%, -1%, 0, +1%, +2%)
    const waccSteps = [-2.0, -1.0, 0, 1.0, 2.0].map((delta) =>
        Math.max(4.0, Number((baseWacc + delta).toFixed(2)))
    );

    // 5 Terminal Growth steps centered around base (-1.0%, -0.5%, 0, +0.5%, +1.0%)
    const growthSteps = [-1.0, -0.5, 0, 0.5, 1.0].map((delta) =>
        Math.max(0.5, Number((baseTerminalGrowth + delta).toFixed(2)))
    );

    const matrix = waccSteps.map((waccPct) => {
        const r = waccPct / 100;

        return growthSteps.map((gPct) => {
            const g = gPct / 100;

            // Mathematical guardrail: r must exceed g to prevent negative denominators
            if (r <= g + 0.002) {
                return {
                    wacc: waccPct,
                    terminalGrowth: gPct,
                    fairValue: 0,
                    marginOfSafety: -100,
                };
            }

            const fairValue = Number(runDcf({ ...inputs, terminalGrowth: g, discountRate: r }).fairValue.toFixed(2));
            const marginOfSafety =
                fairValue > 0
                    ? Number((((fairValue - currentPrice) / fairValue) * 100).toFixed(1))
                    : -100;

            return {
                wacc: waccPct,
                terminalGrowth: gPct,
                fairValue,
                marginOfSafety,
            };
        });
    });

    return { waccSteps, growthSteps, matrix };
}

export default function CompanyShow({ company, historical, dcf_models, maintenance_capex, saved_scenarios, multiples, peers=[], industry_benchmarks, }: Props) {
    // Interactive DCF State (starts on the conservative model)
    const [model, setModel] = useState<DcfModelKey>('conservative');
    const stage2Years = dcf_models[model].stage_2_years;
    const horizonYears = 5 + stage2Years;
    const [baseFcfBillion, setBaseFcfBillion] = useState<number>(
        Number((dcf_models.conservative.base_owner_earnings / 1e9).toFixed(2))
    );
    const [growthPct, setGrowthPct] = useState<number>(dcf_models.conservative.growth_stage_1 * 100);
    const [growth2Pct, setGrowth2Pct] = useState<number>(dcf_models.conservative.growth_stage_2 * 100);
    const [terminalGrowthPct, setTerminalGrowthPct] = useState<number>(
        dcf_models.conservative.terminal_growth * 100
    );
    const [waccPct, setWaccPct] = useState<number>(dcf_models.conservative.wacc * 100);
    const [investmentsBillion, setInvestmentsBillion] = useState<number>(
        Number((dcf_models.conservative.non_operating_investments / 1e9).toFixed(2))
    );
    const [sharesBillion, setSharesBillion] = useState<number>(
        Number((dcf_models.conservative.shares_outstanding / 1e9).toFixed(2))
    );

    // Maintenance CapEx what-if: share of trailing CapEx needed to sustain current earnings
    const defaultMaintenanceSharePct = Number(((maintenance_capex.default_share ?? 0) * 100).toFixed(1));
    const [maintenanceSharePct, setMaintenanceSharePct] = useState<number>(defaultMaintenanceSharePct);
    const ttmCapex = maintenance_capex.ttm_capex ?? 0;
    // Reference points for the slider: a low estimate (depreciation) and a high one (Greenwald)
    const maintenanceMarkers = [
        { label: 'D&A proxy', pct: defaultMaintenanceSharePct },
        ...(maintenance_capex.greenwald_share !== null
            ? [{ label: 'Greenwald', pct: Number((maintenance_capex.greenwald_share * 100).toFixed(1)) }]
            : []),
    ];
    const canAdjustMaintenance = dcf_models[model].base_before_maintenance_capex !== null && ttmCapex > 0;

    // Rebuilds the base figure: (base before maintenance CapEx) - share x TTM CapEx
    const applyMaintenanceShare = (sharePct: number) => {
        const before = dcf_models[model].base_before_maintenance_capex;
        setMaintenanceSharePct(sharePct);
        if (before !== null) {
            setBaseFcfBillion(Number(((before - (sharePct / 100) * ttmCapex) / 1e9).toFixed(2)));
        }
    };

    // Switching model loads that model's base figure and default assumptions
    const selectModel = (next: DcfModelKey) => {
        const d = dcf_models[next];
        setModel(next);
        setMaintenanceSharePct(defaultMaintenanceSharePct);
        setActiveScenarioName(next === 'conservative' ? 'Base Case' : 'Franchise Case');
        setBaseFcfBillion(Number((d.base_owner_earnings / 1e9).toFixed(2)));
        setGrowthPct(Number((d.growth_stage_1 * 100).toFixed(1)));
        setGrowth2Pct(Number((d.growth_stage_2 * 100).toFixed(1)));
        setTerminalGrowthPct(Number((d.terminal_growth * 100).toFixed(1)));
        setWaccPct(Number((d.wacc * 100).toFixed(2)));
        setInvestmentsBillion(Number((d.non_operating_investments / 1e9).toFixed(2)));
        setSharesBillion(Number((d.shares_outstanding / 1e9).toFixed(2)));
    };

    const [activeScenarioName, setActiveScenarioName] = useState<string>('Base Case');
    const [isSaving, setIsSaving] = useState(false);
    const [saveSuccess, setSaveSuccess] = useState(false);

    const applyScenario = (s: SavedScenario) => {
        setModel(s.model === 'franchise' ? 'franchise' : 'conservative');
        setActiveScenarioName(s.scenario_name);
        setBaseFcfBillion(Number((s.base_fcf / 1e9).toFixed(2)));
        setGrowthPct(Number((s.growth_stage_1 * 100).toFixed(1)));
        setGrowth2Pct(Number(((s.growth_stage_2 ?? 0) * 100).toFixed(1)));
        setTerminalGrowthPct(Number((s.terminal_growth * 100).toFixed(1)));
        setWaccPct(Number((s.wacc * 100).toFixed(2)));
        // Scenarios saved before debt was dropped from the model keep their net effect
        setInvestmentsBillion(Number(((s.cash_and_equivalents - s.total_debt) / 1e9).toFixed(2)));
        setSharesBillion(Number((s.shares_outstanding / 1e9).toFixed(2)));
    };

    const handleSaveScenario = (e: React.FormEvent) => {
        e.preventDefault();
        setIsSaving(true);

        router.post(
            `/companies/${company.ticker}/scenarios`,
            {
                scenario_name: activeScenarioName,
                model,
                base_fcf: baseFcfBillion * 1e9,
                growth_stage_1: growthPct / 100,
                growth_stage_2: stage2Years > 0 ? growth2Pct / 100 : null,
                terminal_growth: terminalGrowthPct / 100,
                wacc: waccPct / 100,
                cash_and_equivalents: investmentsBillion * 1e9,
                total_debt: 0,
                shares_outstanding: sharesBillion * 1e9,
                calculated_fair_value: valuation.fairValue,
                notes: `Valued at $${valuation.fairValue} with ${growthPct}% 5Y growth & ${waccPct}% WACC`,
            },
            {
                preserveScroll: true,
                onSuccess: () => {
                    setIsSaving(false);
                    setSaveSuccess(true);
                    setTimeout(() => setSaveSuccess(false), 2500);
                },
                onError: () => setIsSaving(false),
            }
        );
    };

    const sensitivity = useMemo(() => {
        return generateSensitivityMatrix(
            {
                base: baseFcfBillion * 1e9,
                growthStage1: growthPct / 100,
                growthStage2: growth2Pct / 100,
                stage2Years,
                investments: investmentsBillion * 1e9,
                shares: sharesBillion * 1e9,
            },
            waccPct,
            terminalGrowthPct,
            company.current_price
        );
    }, [
            baseFcfBillion,
            growthPct,
            growth2Pct,
            stage2Years,
            waccPct,
            terminalGrowthPct,
            investmentsBillion,
            sharesBillion,
            company.current_price
    ]);

    // Live Reactive Valuation Calculation
    const valuation = useMemo(() => {
        const gTerm = terminalGrowthPct / 100;
        const result = runDcf({
            base: baseFcfBillion * 1e9,
            growthStage1: growthPct / 100,
            growthStage2: growth2Pct / 100,
            stage2Years,
            terminalGrowth: gTerm,
            discountRate: Math.max(waccPct / 100, gTerm + 0.005),
            investments: investmentsBillion * 1e9,
            shares: sharesBillion * 1e9,
        });
        const marginOfSafety =
            result.fairValue > 0 ? ((result.fairValue - company.current_price) / result.fairValue) * 100 : 0;

        return {
            pvExplicit: result.pvExplicit / 1e9,
            terminalValue: result.terminalValue / 1e9,
            pvTerminalValue: result.pvTerminalValue / 1e9,
            earningsValue: result.earningsValue / 1e9,
            equityValue: result.equityValue / 1e9,
            fairValue: Number(result.fairValue.toFixed(2)),
            marginOfSafety: Number(marginOfSafety.toFixed(1)),
            projections: result.projections,
        };
    }, [
        baseFcfBillion,
        growthPct,
        growth2Pct,
        stage2Years,
        terminalGrowthPct,
        waccPct,
        investmentsBillion,
        sharesBillion,
        company.current_price,
    ]);

    const formatCurrency = (val: number) => {
        return new Intl.NumberFormat('en-US', {
            style: 'currency',
            currency: company.currency === 'MYR' ? 'MYR' : 'USD',
        }).format(val);
    };

    const breadcrumbs = [
        { title: 'Dashboard', href: '/dashboard' },
        { title: company.ticker, href: `/companies/${company.ticker}` },
    ];

    return (
        <AppLayout breadcrumbs={breadcrumbs}>
            <Head title={`${company.ticker} — Valuation Deep Dive`} />

            <div className="flex h-full flex-1 flex-col gap-6 p-4">
                {/* Company Header */}
                <div className="flex flex-col justify-between gap-4 md:flex-row md:items-center">
                    <div>
                        <div className="flex items-center gap-2">
                            <h1 className="text-3xl font-extrabold tracking-tight">{company.name}</h1>
                            <Badge variant="secondary" className="font-mono text-sm">
                                {company.ticker}
                            </Badge>
                            <Badge variant="outline">{company.exchange}</Badge>
                        </div>
                        <p className="text-sm text-muted-foreground">{company.industry}</p>
                    </div>
                    <div className="flex items-center gap-6">
                        <div className="text-right">
                            <div className="text-xs text-muted-foreground">Market Price</div>
                            <div className="text-2xl font-bold">{formatCurrency(company.current_price)}</div>
                        </div>
                        <div className="text-right">
                            <div className="text-xs text-muted-foreground">Daily Return</div>
                            <div
                                className={`text-lg font-semibold ${
                                    company.daily_return >= 0 ? 'text-emerald-600' : 'text-rose-600'
                                }`}
                            >
                                {company.daily_return > 0 ? `+${company.daily_return}%` : `${company.daily_return}%`}
                            </div>
                        </div>
                    </div>
                </div>

                <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-5">
                    <Card>
                        <CardContent className="p-4">
                            <div className="text-xs text-muted-foreground font-medium uppercase">Trailing P/E (GAAP, TTM)</div>
                            <div className="text-2xl font-bold tracking-tight">
                                {multiples.pe_ratio !== null ? `${multiples.pe_ratio}x` : 'N/A'}
                            </div>
                            <div className="text-[11px] text-muted-foreground mt-1">
                                TTM Net Income: ${(multiples.ttm_net_income / 1e9).toFixed(2)}B
                            </div>
                        </CardContent>
                    </Card>

                    <Card>
                        <CardContent className="p-4">
                            <div className="text-xs text-muted-foreground font-medium uppercase">Normalized EPS (TTM)</div>
                            <div className="text-2xl font-bold tracking-tight">
                                {multiples.normalized_eps_ttm !== null ? formatCurrency(multiples.normalized_eps_ttm) : 'N/A'}
                            </div>
                            <div className="text-[11px] text-muted-foreground mt-1">
                                GAAP Diluted EPS: {multiples.eps_diluted_ttm !== null ? formatCurrency(multiples.eps_diluted_ttm) : 'N/A'}
                            </div>
                        </CardContent>
                    </Card>

                    <Card>
                        <CardContent className="p-4">
                            <div className="text-xs text-muted-foreground font-medium uppercase">Price / Free Cash Flow</div>
                            <div className="text-2xl font-bold tracking-tight">
                                {multiples.p_fcf_ratio !== null ? `${multiples.p_fcf_ratio}x` : 'N/A'}
                            </div>
                            <div className="text-[11px] text-muted-foreground mt-1">
                                TTM FCF: ${(multiples.ttm_fcf / 1e9).toFixed(2)}B
                            </div>
                        </CardContent>
                    </Card>

                    <Card>
                        <CardContent className="p-4">
                            <div className="text-xs text-muted-foreground font-medium uppercase">EV / Sales</div>
                            <div className="text-2xl font-bold tracking-tight">
                                {multiples.ev_sales_ratio !== null ? `${multiples.ev_sales_ratio}x` : 'N/A'}
                            </div>
                            <div className="text-[11px] text-muted-foreground mt-1">
                                EV: ${(multiples.enterprise_value / 1e9).toFixed(2)}B
                            </div>
                        </CardContent>
                    </Card>

                    <Card>
                        <CardContent className="p-4">
                            <div className="text-xs text-muted-foreground font-medium uppercase">EV / Operating Income</div>
                            <div className="text-2xl font-bold tracking-tight">
                                {multiples.ev_ebit_ratio !== null ? `${multiples.ev_ebit_ratio}x` : 'N/A'}
                            </div>
                            <div className="text-[11px] text-muted-foreground mt-1">
                                Market Cap: ${(multiples.market_cap / 1e9).toFixed(2)}B
                            </div>
                        </CardContent>
                    </Card>
                </div>

                {/* Historical Fundamentals Chart */}
                <Card>
                    <CardHeader>
                        <CardTitle>Historical Financial Performance</CardTitle>
                        <CardDescription>
                            Historical Revenue, Net Income, and Free Cash Flow in billions ({company.currency})
                        </CardDescription>
                    </CardHeader>
                    <CardContent>
                        <div className="h-[360px] w-full">
                            <ResponsiveContainer width="100%" height="100%">
                                <ComposedChart
                                    data={historical.map((h) => ({
                                        period: h.period,
                                        Revenue: Number((h.revenue / 1e9).toFixed(2)),
                                        'Net Income': Number((h.net_income / 1e9).toFixed(2)),
                                        'Free Cash Flow': Number((h.free_cash_flow / 1e9).toFixed(2)),
                                    }))}
                                    margin={{ top: 20, right: 30, left: 10, bottom: 20 }}
                                >
                                    <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
                                    <XAxis dataKey="period" tick={{ fontSize: 12 }} />
                                    <YAxis tickFormatter={(val) => `$${val}B`} tick={{ fontSize: 12 }} />
                                    <Tooltip formatter={(value: number | string | undefined) => [`$${value ?? 0}B`]} />
                                    <Legend />
                                    <Bar dataKey="Revenue" fill="#3b82f6" radius={[4, 4, 0, 0]} />
                                    <Bar dataKey="Net Income" fill="#10b981" radius={[4, 4, 0, 0]} />
                                    <Line
                                        type="monotone"
                                        dataKey="Free Cash Flow"
                                        stroke="#8b5cf6"
                                        strokeWidth={3}
                                        dot={{ r: 4 }}
                                    />
                                </ComposedChart>
                            </ResponsiveContainer>
                        </div>
                    </CardContent>
                </Card>

                {/* Saved Scenarios Bar */}
                <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border bg-neutral-50/50 p-3 dark:bg-neutral-900/50">
                    <div className="flex flex-wrap items-center gap-2">
                        <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1">
                            <Bookmark className="h-3.5 w-3.5" /> Scenarios:
                        </span>
                        {saved_scenarios.length === 0 ? (
                            <span className="text-xs text-muted-foreground italic">No saved theses yet</span>
                        ) : (
                            saved_scenarios.map((s) => (
                                <Button
                                    key={s.id}
                                    type="button"
                                    variant={activeScenarioName === s.scenario_name ? 'default' : 'outline'}
                                    size="sm"
                                    className="h-7 text-xs font-medium"
                                    onClick={() => applyScenario(s)}
                                >
                                    {s.scenario_name}
                                </Button>
                            ))
                        )}
                    </div>

                    {/* Inline Save Form */}
                    <form onSubmit={handleSaveScenario} className="flex items-center gap-2">
                        <Input
                            value={activeScenarioName}
                            onChange={(e) => setActiveScenarioName(e.target.value)}
                            placeholder="Scenario label..."
                            className="h-8 w-36 text-xs"
                            required
                        />
                        <Button type="submit" size="sm" variant="secondary" className="h-8 gap-1.5 text-xs" disabled={isSaving}>
                            {saveSuccess ? (
                                <>
                                    <Check className="h-3.5 w-3.5 text-emerald-600" /> Saved
                                </>
                            ) : (
                                <>
                                    <Save className="h-3.5 w-3.5" /> {isSaving ? 'Saving...' : 'Save'}
                                </>
                            )}
                        </Button>
                    </form>
                </div>

                {/* Interactive DCF Engine */}
                <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
                    {/* Assumptions Controls */}
                    <Card className="lg:col-span-3">
                        <CardHeader>
                            <CardTitle>Discounted Cash Flow Assumptions</CardTitle>
                            <Tabs value={model} onValueChange={(value) => selectModel(value as DcfModelKey)} className="pt-2">
                                <TabsList>
                                    {(Object.keys(DCF_MODEL_COPY) as DcfModelKey[]).map((key) => (
                                        <TabsTrigger key={key} value={key}>
                                            {DCF_MODEL_COPY[key].label}
                                            {dcf_models[key].fair_value_per_share !== null && (
                                                <span className="ml-2 font-mono text-xs text-muted-foreground">
                                                    {formatCurrency(dcf_models[key].fair_value_per_share as number)}
                                                </span>
                                            )}
                                        </TabsTrigger>
                                    ))}
                                </TabsList>
                            </Tabs>
                            <CardDescription>
                                {DCF_MODEL_COPY[model].description} Adjust the parameters to recalculate intrinsic value.
                            </CardDescription>
                        </CardHeader>
                        <CardContent className="space-y-6">
                            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                                <div className="space-y-2">
                                    <Label>{DCF_MODEL_COPY[model].baseLabel}</Label>
                                    <Input
                                        type="number"
                                        step="0.1"
                                        value={baseFcfBillion}
                                        onChange={(e) => setBaseFcfBillion(parseFloat(e.target.value) || 0)}
                                    />
                                </div>
                                <div className="space-y-2">
                                    <Label>Shares Outstanding (Billion)</Label>
                                    <Input
                                        type="number"
                                        step="0.05"
                                        value={sharesBillion}
                                        onChange={(e) => setSharesBillion(parseFloat(e.target.value) || 0.1)}
                                    />
                                </div>
                                <div className="space-y-2 sm:col-span-2">
                                    <Label>Long-Term Investments Not In Earnings ($B)</Label>
                                    <Input
                                        type="number"
                                        step="0.1"
                                        value={investmentsBillion}
                                        onChange={(e) => setInvestmentsBillion(parseFloat(e.target.value) || 0)}
                                    />
                                    <p className="text-[11px] text-muted-foreground">
                                        Debt and cash are not adjusted for: the base figure is after interest paid and earned, so it already belongs to shareholders.
                                    </p>
                                </div>
                            </div>

                            <Separator />

                            {/* Sliders */}
                            <div className="space-y-5">
                                {canAdjustMaintenance && (
                                    <div>
                                        <div className="flex justify-between text-sm">
                                            <Label>Maintenance CapEx Share of Total CapEx: {maintenanceSharePct}%</Label>
                                            <span className="text-xs text-muted-foreground">
                                                ${((maintenanceSharePct / 100) * ttmCapex / 1e9).toFixed(2)}B of ${(ttmCapex / 1e9).toFixed(2)}B TTM CapEx
                                            </span>
                                        </div>
                                        <Slider
                                            value={[maintenanceSharePct]}
                                            min={0}
                                            max={100}
                                            step={0.5}
                                            onValueChange={(val) => applyMaintenanceShare(val[0])}
                                            className="mt-2"
                                        />
                                        {/* Reference markers: click one to jump the slider to that estimate */}
                                        <div className="relative mt-1 h-9">
                                            {maintenanceMarkers.map((marker) => (
                                                <button
                                                    key={marker.label}
                                                    type="button"
                                                    onClick={() => applyMaintenanceShare(marker.pct)}
                                                    className="absolute top-0 flex -translate-x-1/2 flex-col items-center text-[10px] leading-tight text-muted-foreground hover:text-primary"
                                                    style={{ left: `${marker.pct}%` }}
                                                >
                                                    <span className="h-2 w-px bg-current" />
                                                    <span className="whitespace-nowrap font-medium">{marker.label}</span>
                                                    <span className="font-mono">{marker.pct}%</span>
                                                </button>
                                            ))}
                                        </div>
                                        <p className="mt-1 text-[11px] text-muted-foreground">
                                            Maintenance CapEx is not reported, so it has to be estimated. The D&A proxy tends to run low for a fast-growing asset base and the Greenwald estimate tends to run high when capacity is built ahead of demand; the truth usually lies between them. Moving the slider recalculates the base figure above.
                                        </p>
                                    </div>
                                )}

                                <div>
                                    <div className="flex justify-between text-sm">
                                        <Label>Annual Owner Earnings Growth, Years 1-5: {growthPct}%</Label>
                                    </div>
                                    <Slider
                                        value={[growthPct]}
                                        min={-10}
                                        max={35}
                                        step={0.5}
                                        onValueChange={(val) => setGrowthPct(val[0])}
                                        className="mt-2"
                                    />
                                </div>

                                {stage2Years > 0 && (
                                    <div>
                                        <div className="flex justify-between text-sm">
                                            <Label>Annual Owner Earnings Growth, Years 6-10: {growth2Pct}%</Label>
                                        </div>
                                        <Slider
                                            value={[growth2Pct]}
                                            min={-10}
                                            max={35}
                                            step={0.5}
                                            onValueChange={(val) => setGrowth2Pct(val[0])}
                                            className="mt-2"
                                        />
                                    </div>
                                )}

                                <div>
                                    <div className="flex justify-between text-sm">
                                        <Label>Discount Rate / WACC: {waccPct}%</Label>
                                    </div>
                                    <Slider
                                        value={[waccPct]}
                                        min={5}
                                        max={16}
                                        step={0.25}
                                        onValueChange={(val) => setWaccPct(val[0])}
                                        className="mt-2"
                                    />
                                </div>

                                <div>
                                    <div className="flex justify-between text-sm">
                                        <Label>Perpetual Terminal Growth Rate: {terminalGrowthPct}%</Label>
                                    </div>
                                    <Slider
                                        value={[terminalGrowthPct]}
                                        min={1}
                                        max={4.5}
                                        step={0.1}
                                        onValueChange={(val) => setTerminalGrowthPct(val[0])}
                                        className="mt-2"
                                    />
                                </div>
                            </div>
                        </CardContent>
                    </Card>

                    {/* Output Valuation Card */}
                    <Card className="flex flex-col justify-between">
                        <CardHeader>
                            <CardTitle>Intrinsic Valuation Output</CardTitle>
                            <CardDescription>{DCF_MODEL_COPY[model].label} model, Gordon Growth terminal value</CardDescription>
                        </CardHeader>
                        <CardContent className="space-y-5">
                            <div className="rounded-lg border bg-neutral-50 p-4 dark:bg-neutral-900">
                                <div className="text-xs text-muted-foreground uppercase">Estimated Fair Value</div>
                                <div className="text-3xl font-extrabold text-primary">
                                    {formatCurrency(valuation.fairValue)}
                                </div>
                                <div className="mt-2 flex items-center gap-2">
                                    <Badge
                                        variant={valuation.marginOfSafety >= 0 ? 'default' : 'destructive'}
                                    >
                                        {valuation.marginOfSafety >= 10 ? 'Undervalued' : 'Overvalued'}
                                    </Badge>
                                    <span className="text-xs text-muted-foreground">
                                        {Math.abs(valuation.marginOfSafety)}% margin of safety
                                    </span>
                                </div>
                            </div>

                            <div className="space-y-2 text-sm">
                                <div className="flex justify-between">
                                    <span className="text-muted-foreground">PV of Explicit {horizonYears}Y Owner Earnings</span>
                                    <span className="font-mono font-medium">${valuation.pvExplicit.toFixed(2)}B</span>
                                </div>
                                <div className="flex justify-between">
                                    <span className="text-muted-foreground">PV of Terminal Value</span>
                                    <span className="font-mono font-medium">
                                        ${valuation.pvTerminalValue.toFixed(2)}B
                                    </span>
                                </div>
                                <div className="flex justify-between border-t pt-1 font-semibold">
                                    <span>Value of Owner Earnings</span>
                                    <span className="font-mono">${valuation.earningsValue.toFixed(2)}B</span>
                                </div>
                                <div className="flex justify-between">
                                    <span className="text-muted-foreground">Plus Long-Term Investments</span>
                                    <span className="font-mono font-medium">
                                        ${investmentsBillion.toFixed(2)}B
                                    </span>
                                </div>
                                <div className="flex justify-between border-t pt-1 font-bold text-neutral-900 dark:text-neutral-100">
                                    <span>Equity Value</span>
                                    <span className="font-mono">${valuation.equityValue.toFixed(2)}B</span>
                                </div>
                            </div>
                        </CardContent>
                    </Card>
                    <Card className="lg:col-span-2">
                        <CardHeader>
                            <CardTitle>Valuation Sensitivity Matrix</CardTitle>
                            <CardDescription>
                                Estimated intrinsic value per share across varying Discount Rates (WACC) and Perpetual Terminal Growth Rates.
                            </CardDescription>
                        </CardHeader>
                        <CardContent>
                            <div className="overflow-x-auto">
                                <table className="min-w-full text-center text-sm border-collapse">
                                    <thead>
                                        <tr>
                                            <th className="border p-2 bg-neutral-100 dark:bg-neutral-800 font-semibold text-xs text-muted-foreground">
                                                WACC \ Terminal Growth
                                            </th>
                                            {sensitivity.growthSteps.map((g) => (
                                                <th
                                                    key={g}
                                                    className={`border p-2 font-mono text-xs ${
                                                        g === terminalGrowthPct
                                                            ? 'bg-primary/10 font-bold text-primary'
                                                            : 'bg-neutral-50 dark:bg-neutral-900 text-muted-foreground'
                                                    }`}
                                                >
                                                    {g.toFixed(1)}%
                                                </th>
                                            ))}
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {sensitivity.matrix.map((row, rowIdx) => {
                                            const currentWacc = sensitivity.waccSteps[rowIdx];
                                            const isBaseWacc = currentWacc === waccPct;

                                            return (
                                                <tr key={currentWacc}>
                                                    <td
                                                        className={`border p-2 font-mono text-xs font-semibold ${
                                                            isBaseWacc
                                                                ? 'bg-primary/10 text-primary'
                                                                : 'bg-neutral-50 dark:bg-neutral-900 text-muted-foreground'
                                                        }`}
                                                    >
                                                        {currentWacc.toFixed(2)}%
                                                    </td>
                                                    {row.map((cell) => {
                                                        const isCenter =
                                                            isBaseWacc && cell.terminalGrowth === terminalGrowthPct;
                                                        const isUndervalued = cell.fairValue > company.current_price;

                                                        return (
                                                            <td
                                                                key={`${cell.wacc}-${cell.terminalGrowth}`}
                                                                className={`border p-3 font-mono text-xs transition-colors ${
                                                                    isCenter
                                                                        ? 'ring-2 ring-primary ring-inset font-bold'
                                                                        : ''
                                                                } ${
                                                                    cell.fairValue === 0
                                                                        ? 'bg-neutral-100 dark:bg-neutral-800 text-muted-foreground'
                                                                        : isUndervalued
                                                                        ? 'bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300'
                                                                        : 'bg-rose-50 dark:bg-rose-950/40 text-rose-700 dark:text-rose-300'
                                                                }`}
                                                            >
                                                                <div className="font-bold">
                                                                    {cell.fairValue > 0 ? formatCurrency(cell.fairValue) : 'N/A'}
                                                                </div>
                                                                <div className="text-[10px] opacity-80">
                                                                    {cell.fairValue > 0
                                                                        ? `${cell.marginOfSafety >= 0 ? '+' : ''}${cell.marginOfSafety}%`
                                                                        : '—'}
                                                                </div>
                                                            </td>
                                                        );
                                                    })}
                                                </tr>
                                            );
                                        })}
                                    </tbody>
                                </table>
                            </div>
                        </CardContent>
                    </Card>
                    {/* Industry Peer Valuation Comps */}
                    <Card className="lg:col-span-3">
                        <CardHeader>
                            <div className="flex flex-col justify-between gap-1 sm:flex-row sm:items-center">
                                <div>
                                    <CardTitle>Industry Peer Comparison</CardTitle>
                                    <CardDescription>
                                        Relative trading multiples against companies operating in {company.industry}
                                    </CardDescription>
                                </div>
                                {industry_benchmarks?.median_pe && multiples?.pe_ratio && (
                                    <div className="flex items-center gap-2">
                                        <span className="text-xs text-muted-foreground">P/E vs Sector Median:</span>
                                        {multiples.pe_ratio < industry_benchmarks.median_pe ? (
                                            <Badge variant="outline" className="border-emerald-600/30 bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-300">
                                                {Math.round(((industry_benchmarks.median_pe - multiples.pe_ratio) / industry_benchmarks.median_pe) * 100)}% Discount
                                            </Badge>
                                        ) : (
                                            <Badge variant="outline" className="border-rose-600/30 bg-rose-50 text-rose-700 dark:bg-rose-950/40 dark:text-rose-300">
                                                {Math.round(((multiples.pe_ratio - industry_benchmarks.median_pe) / industry_benchmarks.median_pe) * 100)}% Premium
                                            </Badge>
                                        )}
                                    </div>
                                )}
                            </div>
                        </CardHeader>
                        <CardContent>
                            <div className="overflow-x-auto">
                                <table className="min-w-full text-left text-sm border-collapse">
                                    <thead>
                                        <tr className="border-b bg-neutral-50/50 dark:bg-neutral-900/50 text-xs text-muted-foreground">
                                            <th className="p-3 font-semibold">Company</th>
                                            <th className="p-3 text-right font-semibold">Share Price</th>
                                            <th className="p-3 text-right font-semibold">P/E</th>
                                            <th className="p-3 text-right font-semibold">P/FCF</th>
                                            <th className="p-3 text-right font-semibold">EV / Sales</th>
                                            <th className="p-3 text-right font-semibold">EV / EBIT</th>
                                            <th className="p-3 text-right font-semibold">Net Margin</th>
                                        </tr>
                                    </thead>
                                    <tbody className="divide-y font-mono text-xs">
                                        {/* Target Company Row (Highlighted) */}
                                        <tr className="bg-primary/5 font-semibold">
                                            <td className="p-3 font-sans">
                                                <span className="font-bold text-primary">{company.ticker}</span>
                                                <span className="ml-2 text-[11px] text-muted-foreground">({company.name})</span>
                                                <Badge variant="secondary" className="ml-2 text-[10px]">Target</Badge>
                                            </td>
                                            <td className="p-3 text-right">${company.current_price.toFixed(2)}</td>
                                            <td className="p-3 text-right">{multiples?.pe_ratio ? `${multiples.pe_ratio}x` : '—'}</td>
                                            <td className="p-3 text-right">{multiples?.p_fcf_ratio ? `${multiples.p_fcf_ratio}x` : '—'}</td>
                                            <td className="p-3 text-right">{multiples?.ev_sales_ratio ? `${multiples.ev_sales_ratio}x` : '—'}</td>
                                            <td className="p-3 text-right">{multiples?.ev_ebit_ratio ? `${multiples.ev_ebit_ratio}x` : '—'}</td>
                                            <td className="p-3 text-right">
                                                {historical.length > 0 ? `${historical[historical.length - 1].net_margin}%` : '—'}
                                            </td>
                                        </tr>

                                        {/* Sector Median Benchmark Row */}
                                        <tr className="border-t-2 border-dashed bg-neutral-100/70 dark:bg-neutral-800/70 font-semibold text-muted-foreground">
                                            <td className="p-3 font-sans text-xs italic">Industry Median Benchmark</td>
                                            <td className="p-3 text-right">—</td>
                                            <td className="p-3 text-right">{industry_benchmarks?.median_pe ? `${industry_benchmarks.median_pe}x` : '—'}</td>
                                            <td className="p-3 text-right">{industry_benchmarks?.median_p_fcf ? `${industry_benchmarks.median_p_fcf}x` : '—'}</td>
                                            <td className="p-3 text-right">{industry_benchmarks?.median_ev_sales ? `${industry_benchmarks.median_ev_sales}x` : '—'}</td>
                                            <td className="p-3 text-right">{industry_benchmarks?.median_ev_ebit ? `${industry_benchmarks.median_ev_ebit}x` : '—'}</td>
                                            <td className="p-3 text-right">—</td>
                                        </tr>

                                        {/* Peer Rows */}
                                        {peers.length === 0 ? (
                                            <tr>
                                                <td colSpan={7} className="p-4 text-center font-sans text-xs text-muted-foreground italic">
                                                    No peer companies currently recorded in this industry sector.
                                                </td>
                                            </tr>
                                        ) : (
                                            peers.map((peer) => (
                                                <tr key={peer.ticker} className="hover:bg-neutral-50 dark:hover:bg-neutral-900/50">
                                                    <td className="p-3 font-sans">
                                                        <Link href={`/companies/${peer.ticker}`} className="font-semibold text-primary hover:underline">
                                                            {peer.ticker}
                                                        </Link>
                                                        <span className="ml-2 text-muted-foreground">{peer.name}</span>
                                                    </td>
                                                    <td className="p-3 text-right">${peer.price.toFixed(2)}</td>
                                                    <td className="p-3 text-right">{peer.pe ? `${peer.pe}x` : '—'}</td>
                                                    <td className="p-3 text-right">{peer.p_fcf ? `${peer.p_fcf}x` : '—'}</td>
                                                    <td className="p-3 text-right">{peer.ev_sales ? `${peer.ev_sales}x` : '—'}</td>
                                                    <td className="p-3 text-right">{peer.ev_ebit ? `${peer.ev_ebit}x` : '—'}</td>
                                                    <td className="p-3 text-right">{peer.net_margin}%</td>
                                                </tr>
                                            ))
                                        )}
                                    </tbody>
                                </table>
                            </div>
                        </CardContent>
                    </Card>
                </div>
                <FinancialStatementsTable statements={historical} currency={company.currency} />
            </div>
        </AppLayout>
    );
}
