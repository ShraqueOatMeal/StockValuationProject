import { useState } from 'react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Badge } from '@/components/ui/badge';

interface Props {
    statements: DetailedStatementRecord[];
    currency: string;
}

export function FinancialStatementsTable({ statements, currency }: Props) {
    const [viewMode, setViewMode] = useState<'billions' | 'millions'>('billions');
    const scale = viewMode === 'billions' ? 1e9 : 1e6;
    const unitLabel = viewMode === 'billions' ? '($B)' : '($M)';

    // Chronological order left-aligned (most recent on the left) just extract 10
    const periods = statements.slice(0, 10);

    const fmt = (val: number) => {
        return (val / scale).toLocaleString('en-US', {
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
        });
    };

    return (
        <Card>
            <CardHeader className="flex flex-col justify-between gap-2 sm:flex-row sm:items-center">
                <div>
                    <CardTitle>Historical Financial Statements</CardTitle>
                    <CardDescription>
                        Audit quarterly GAAP line items across the Income Statement, Balance Sheet, and Cash Flow Statement.
                    </CardDescription>
                </div>
                <div className="flex items-center gap-2">
                    <button
                        type="button"
                        onClick={() => setViewMode(viewMode === 'billions' ? 'millions' : 'billions')}
                        className="rounded-md border bg-neutral-100 px-2.5 py-1 text-xs font-semibold hover:bg-neutral-200 dark:bg-neutral-800 dark:hover:bg-neutral-700"
                    >
                        Scale: {viewMode.toUpperCase()}
                    </button>
                </div>
            </CardHeader>
            <CardContent>
                <Tabs defaultValue="income" className="w-full">
                    <TabsList className="mb-4 grid w-full grid-cols-3 max-w-md">
                        <TabsTrigger value="income">Income Statement</TabsTrigger>
                        <TabsTrigger value="balance">Balance Sheet</TabsTrigger>
                        <TabsTrigger value="cashflow">Cash Flow</TabsTrigger>
                    </TabsList>

                    {/* 1. INCOME STATEMENT */}
                    <TabsContent value="income">
                        <div className="overflow-x-auto">
                            <table className="min-w-full text-sm border-collapse">
                                <thead>
                                    <tr className="border-b bg-neutral-50/50 dark:bg-neutral-900/50 text-xs text-muted-foreground">
                                        <th className="p-3 text-left font-semibold">Line Item {unitLabel}</th>
                                        {periods.map((p) => (
                                            <th key={p.period} className="p-3 text-right font-mono font-medium">
                                                <div>{p.period}</div>
                                                <div className="text-[10px] text-muted-foreground">{p.period_end_date}</div>
                                            </th>
                                        ))}
                                    </tr>
                                </thead>
                                <tbody className="divide-y font-mono text-xs">
                                    <tr className="font-semibold bg-neutral-50/30 dark:bg-neutral-900/20">
                                        <td className="p-3 font-sans">Total Revenue</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">{fmt(p.revenue)}</td>
                                        ))}
                                    </tr>
                                    <tr className="text-muted-foreground">
                                        <td className="p-3 font-sans pl-6">YoY Revenue Growth</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">
                                                {p.revenue_yoy !== null ? (
                                                    <span className={p.revenue_yoy >= 0 ? 'text-emerald-600' : 'text-rose-600'}>
                                                        {p.revenue_yoy > 0 ? `+${p.revenue_yoy}%` : `${p.revenue_yoy}%`}
                                                    </span>
                                                ) : '—'}
                                            </td>
                                        ))}
                                    </tr>
                                    <tr>
                                        <td className="p-3 font-sans">Gross Profit</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">{fmt(p.gross_profit)}</td>
                                        ))}
                                    </tr>
                                    <tr className="text-muted-foreground">
                                        <td className="p-3 font-sans pl-6">Gross Margin</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">{p.gross_margin}%</td>
                                        ))}
                                    </tr>
                                    <tr className="font-medium">
                                        <td className="p-3 font-sans">Operating Income (EBIT)</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">{fmt(p.operating_income)}</td>
                                        ))}
                                    </tr>
                                    <tr className="text-muted-foreground">
                                        <td className="p-3 font-sans pl-6">Operating Margin</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">{p.operating_margin}%</td>
                                        ))}
                                    </tr>
                                    <tr className="font-bold border-t-2">
                                        <td className="p-3 font-sans text-primary">Net Income</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right text-primary">{fmt(p.net_income)}</td>
                                        ))}
                                    </tr>
                                    <tr className="text-muted-foreground">
                                        <td className="p-3 font-sans pl-6">Net Margin</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">{p.net_margin}%</td>
                                        ))}
                                    </tr>
                                </tbody>
                            </table>
                        </div>
                    </TabsContent>

                    {/* 2. BALANCE SHEET */}
                    <TabsContent value="balance">
                        <div className="overflow-x-auto">
                            <table className="min-w-full text-sm border-collapse">
                                <thead>
                                    <tr className="border-b bg-neutral-50/50 dark:bg-neutral-900/50 text-xs text-muted-foreground">
                                        <th className="p-3 text-left font-semibold">Line Item {unitLabel}</th>
                                        {periods.map((p) => (
                                            <th key={p.period} className="p-3 text-right font-mono font-medium">
                                                <div>{p.period}</div>
                                                <div className="text-[10px] text-muted-foreground">{p.period_end_date}</div>
                                            </th>
                                        ))}
                                    </tr>
                                </thead>
                                <tbody className="divide-y font-mono text-xs">
                                    <tr className="font-semibold">
                                        <td className="p-3 font-sans">Cash & Equivalents</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right text-emerald-600 dark:text-emerald-400">
                                                {fmt(p.cash_and_equivalents)}
                                            </td>
                                        ))}
                                    </tr>
                                    <tr>
                                        <td className="p-3 font-sans">Total Assets</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">{fmt(p.total_assets)}</td>
                                        ))}
                                    </tr>
                                    <tr>
                                        <td className="p-3 font-sans">Total Liabilities (Debt + Obligations)</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right text-rose-600 dark:text-rose-400">
                                                {fmt(p.total_liabilities)}
                                            </td>
                                        ))}
                                    </tr>
                                    <tr className="font-bold border-t">
                                        <td className="p-3 font-sans">Stockholders' Equity</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">{fmt(p.stockholders_equity)}</td>
                                        ))}
                                    </tr>
                                    <tr className="text-muted-foreground">
                                        <td className="p-3 font-sans pl-6">Debt-to-Equity Ratio</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">{p.debt_to_equity}x</td>
                                        ))}
                                    </tr>
                                </tbody>
                            </table>
                        </div>
                    </TabsContent>

                    {/* 3. CASH FLOW STATEMENT */}
                    <TabsContent value="cashflow">
                        <div className="overflow-x-auto">
                            <table className="min-w-full text-sm border-collapse">
                                <thead>
                                    <tr className="border-b bg-neutral-50/50 dark:bg-neutral-900/50 text-xs text-muted-foreground">
                                        <th className="p-3 text-left font-semibold">Line Item {unitLabel}</th>
                                        {periods.map((p) => (
                                            <th key={p.period} className="p-3 text-right font-mono font-medium">
                                                <div>{p.period}</div>
                                                <div className="text-[10px] text-muted-foreground">{p.period_end_date}</div>
                                            </th>
                                        ))}
                                    </tr>
                                </thead>
                                <tbody className="divide-y font-mono text-xs">
                                    <tr className="font-semibold">
                                        <td className="p-3 font-sans">Cash from Operations (CFO)</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">{fmt(p.operating_cash_flow)}</td>
                                        ))}
                                    </tr>
                                    <tr>
                                        <td className="p-3 font-sans pl-6">Capital Expenditures (CapEx)</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right text-rose-600 dark:text-rose-400">
                                                -{fmt(p.capital_expenditures)}
                                            </td>
                                        ))}
                                    </tr>
                                    <tr className="font-bold border-t-2 bg-neutral-50/50 dark:bg-neutral-900/40">
                                        <td className="p-3 font-sans text-primary">Free Cash Flow (FCF)</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right text-primary font-bold">
                                                {fmt(p.free_cash_flow)}
                                            </td>
                                        ))}
                                    </tr>
                                    <tr className="text-muted-foreground">
                                        <td className="p-3 font-sans pl-6">FCF / Net Income Conversion</td>
                                        {periods.map((p) => (
                                            <td key={p.period} className="p-3 text-right">
                                                {p.fcf_conversion !== null ? `${p.fcf_conversion}%` : '—'}
                                            </td>
                                        ))}
                                    </tr>
                                </tbody>
                            </table>
                        </div>
                    </TabsContent>
                </Tabs>
            </CardContent>
        </Card>
    );
}
