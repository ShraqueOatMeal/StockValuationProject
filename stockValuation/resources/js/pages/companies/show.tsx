import { useState, useMemo } from 'react';
import AppLayout from '@/layouts/app-layout';
import { Head, Link } from '@inertiajs/react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Slider } from '@/components/ui/slider';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Separator } from '@/components/ui/separator';
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

interface DcfDefaults {
    base_fcf: number;
    growth_stage_1: number;
    terminal_growth: number;
    wacc: number;
    cash: number;
    total_debt: number;
    shares_outstanding: number;
    current_price: number;
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
    dcf_defaults: DcfDefaults;
}

export default function CompanyShow({ company, historical, dcf_defaults }: Props) {
    // Interactive DCF State
    const [baseFcfBillion, setBaseFcfBillion] = useState<number>(
        Number((dcf_defaults.base_fcf / 1e9).toFixed(2))
    );
    const [growthPct, setGrowthPct] = useState<number>(dcf_defaults.growth_stage_1 * 100);
    const [terminalGrowthPct, setTerminalGrowthPct] = useState<number>(
        dcf_defaults.terminal_growth * 100
    );
    const [waccPct, setWaccPct] = useState<number>(dcf_defaults.wacc * 100);
    const [cashBillion, setCashBillion] = useState<number>(
        Number((dcf_defaults.cash / 1e9).toFixed(2))
    );
    const [debtBillion, setDebtBillion] = useState<number>(
        Number((dcf_defaults.total_debt / 1e9).toFixed(2))
    );
    const [sharesBillion, setSharesBillion] = useState<number>(
        Number((dcf_defaults.shares_outstanding / 1e9).toFixed(2))
    );

    // Live Reactive Valuation Calculation
    const valuation = useMemo(() => {
        const baseFcf = baseFcfBillion * 1e9;
        const g1 = growthPct / 100;
        const gTerm = terminalGrowthPct / 100;
        const r = Math.max(waccPct / 100, gTerm + 0.005);
        const cash = cashBillion * 1e9;
        const debt = debtBillion * 1e9;
        const shares = sharesBillion * 1e9;

        let pvExplicit = 0;
        let runningFcf = baseFcf;
        const projections = [];

        for (let year = 1; year <= 5; year++) {
            runningFcf *= 1 + g1;
            const pv = runningFcf / Math.pow(1 + r, year);
            pvExplicit += pv;
            projections.push({
                year: `Year ${year}`,
                fcf: runningFcf / 1e9,
                pv_fcf: pv / 1e9,
            });
        }

        const terminalFcf = runningFcf * (1 + gTerm);
        const terminalValue = terminalFcf / (r - gTerm);
        const pvTerminalValue = terminalValue / Math.pow(1 + r, 5);
        const enterpriseValue = pvExplicit + pvTerminalValue;
        const netDebt = debt - cash;
        const equityValue = enterpriseValue - netDebt;
        const fairValue = shares > 0 ? equityValue / shares : 0;
        const marginOfSafety =
            fairValue > 0 ? ((fairValue - company.current_price) / fairValue) * 100 : 0;

        return {
            pvExplicit: pvExplicit / 1e9,
            terminalValue: terminalValue / 1e9,
            pvTerminalValue: pvTerminalValue / 1e9,
            enterpriseValue: enterpriseValue / 1e9,
            equityValue: equityValue / 1e9,
            fairValue: Number(fairValue.toFixed(2)),
            marginOfSafety: Number(marginOfSafety.toFixed(1)),
            projections,
        };
    }, [
        baseFcfBillion,
        growthPct,
        terminalGrowthPct,
        waccPct,
        cashBillion,
        debtBillion,
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

                {/* Interactive DCF Engine */}
                <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
                    {/* Assumptions Controls */}
                    <Card className="lg:col-span-2">
                        <CardHeader>
                            <CardTitle>Discounted Cash Flow Assumptions</CardTitle>
                            <CardDescription>
                                Adjust cash flow projection parameters to dynamically recalculate intrinsic value.
                            </CardDescription>
                        </CardHeader>
                        <CardContent className="space-y-6">
                            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                                <div className="space-y-2">
                                    <Label>Base Free Cash Flow ($B)</Label>
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
                                <div className="space-y-2">
                                    <Label>Cash & Short Term Investments ($B)</Label>
                                    <Input
                                        type="number"
                                        step="0.1"
                                        value={cashBillion}
                                        onChange={(e) => setCashBillion(parseFloat(e.target.value) || 0)}
                                    />
                                </div>
                                <div className="space-y-2">
                                    <Label>Total Debt ($B)</Label>
                                    <Input
                                        type="number"
                                        step="0.1"
                                        value={debtBillion}
                                        onChange={(e) => setDebtBillion(parseFloat(e.target.value) || 0)}
                                    />
                                </div>
                            </div>

                            <Separator />

                            {/* Sliders */}
                            <div className="space-y-5">
                                <div>
                                    <div className="flex justify-between text-sm">
                                        <Label>5-Year Annual FCF Growth Rate: {growthPct}%</Label>
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
                            <CardDescription>Gordon Growth Terminal Value Model</CardDescription>
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
                                    <span className="text-muted-foreground">PV of Explicit 5Y FCF</span>
                                    <span className="font-mono font-medium">${valuation.pvExplicit.toFixed(2)}B</span>
                                </div>
                                <div className="flex justify-between">
                                    <span className="text-muted-foreground">PV of Terminal Value</span>
                                    <span className="font-mono font-medium">
                                        ${valuation.pvTerminalValue.toFixed(2)}B
                                    </span>
                                </div>
                                <div className="flex justify-between border-t pt-1 font-semibold">
                                    <span>Enterprise Value</span>
                                    <span className="font-mono">${valuation.enterpriseValue.toFixed(2)}B</span>
                                </div>
                                <div className="flex justify-between">
                                    <span className="text-muted-foreground">Net Debt (Debt - Cash)</span>
                                    <span className="font-mono font-medium">
                                        ${(debtBillion - cashBillion).toFixed(2)}B
                                    </span>
                                </div>
                                <div className="flex justify-between border-t pt-1 font-bold text-neutral-900 dark:text-neutral-100">
                                    <span>Equity Value</span>
                                    <span className="font-mono">${valuation.equityValue.toFixed(2)}B</span>
                                </div>
                            </div>
                        </CardContent>
                    </Card>
                </div>
            </div>
        </AppLayout>
    );
}
