import AppLayout from '@/layouts/app-layout';
import { Head } from '@inertiajs/react';
import { Link } from '@inertiajs/react';
import { PageProps } from '@/types';
import {
    Card,
    CardContent,
    CardDescription,
    CardHeader,
    CardTitle,
} from '@/components/ui/card';
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';

export interface WatchlistItem {
    ticker: string;
    name: string;
    currency: string;
    exchange: string;
    industry: string;
    latest_trade_date: string | null;
    close_price: string | number | null;
    daily_return: number | null;
    sma_20: string | number | null;
    sma_50: string | number | null;
    free_cash_flow: string | number | null;
    net_margin: number | null;
    roe: number | null;
}

interface DashboardProps extends PageProps {
    watchlist: WatchlistItem[];
}


const breadcrumbs = [
    {
        title: 'Valuation Dashboard',
        href: '/dashboard',
    }
]

export default function Dashboard({ auth, watchlist }: DashboardProps) {
    const formatCurrency = (
        val: string | number | null,
        currency: string = 'USD'
    ): string => {
        if (val === null || val === undefined || val === '') return '—';
        const numericVal = typeof val === 'string' ? parseFloat(val) : val;
        if (Number.isNaN(numericVal)) return '—';

        return new Intl.NumberFormat('en-US', {
            style: 'currency',
            currency: currency === 'MYR' ? 'MYR' : 'USD',
            maximumFractionDigits: 2,
        }).format(numericVal);
    };

    const formatBillions = (
        val: string | number | null,
        currency: string = 'USD'
    ): string => {
        if (val === null || val === undefined || val === '') return '—';
        const numericVal = typeof val === 'string' ? parseFloat(val) : val;
        if (Number.isNaN(numericVal)) return '—';

        const inBillions = numericVal / 1e9;
        const prefix = currency === 'MYR' ? 'RM ' : '$';
        return `${prefix}${inBillions.toFixed(2)}B`;
    };

    return (
        <AppLayout breadcrumbs={breadcrumbs}>
            <Head title="Valuation Dashboard" />

            <div className="py-12">
                <div className="mx-auto max-w-7xl space-y-6 sm:px-6 lg:px-8">
                    <Card>
                        <CardHeader>
                            <div className="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
                                <div>
                                    <CardTitle className="text-xl font-bold tracking-tight">
                                        Tracked Asset Universe
                                    </CardTitle>
                                    <CardDescription>
                                        Live pricing joined to point-in-time SEC EDGAR XBRL filings and Bursa Malaysia fundamentals.
                                    </CardDescription>
                                </div>
                                <Badge variant="outline" className="w-fit text-xs font-mono">
                                    Schema: gold.fact_daily_market_valuation
                                </Badge>
                            </div>
                        </CardHeader>
                        <CardContent>
                            <div className="rounded-md border">
                                <Table>
                                    <TableHeader>
                                        <TableRow>
                                            <TableHead className="w-[120px]">Ticker</TableHead>
                                            <TableHead>Company</TableHead>
                                            <TableHead className="text-right">Close Price</TableHead>
                                            <TableHead className="text-right">Daily Return</TableHead>
                                            <TableHead className="text-right">SMA (20 / 50)</TableHead>
                                            <TableHead className="text-right">Free Cash Flow</TableHead>
                                            <TableHead className="text-right">ROE</TableHead>
                                            <TableHead className="text-right">As of Date</TableHead>
                                        </TableRow>
                                    </TableHeader>
                                    <TableBody>
                                        {watchlist.length === 0 ? (
                                            <TableRow>
                                                <TableCell colSpan={8} className="h-24 text-center text-muted-foreground">
                                                    No assets found in Gold layer. Run dbt models to materialize data.
                                                </TableCell>
                                            </TableRow>
                                        ) : (
                                            watchlist.map((stock) => {
                                                const isPositive = (stock.daily_return ?? 0) >= 0;

                                                return (
                                                    <TableRow key={stock.ticker}>
                                                        <TableCell className="font-mono font-bold text-primary">
                                                            <Link
                                                                href={`/companies/${stock.ticker}`}
                                                                className="hover:underline flex items-center gap-1"
                                                            >
                                                                {stock.ticker}
                                                            </Link>
                                                        </TableCell>
                                                        <TableCell>
                                                            <div className="font-medium text-neutral-900 dark:text-neutral-100">
                                                                {stock.name}
                                                            </div>
                                                            <div className="text-xs text-muted-foreground">
                                                                {stock.exchange} • {stock.industry}
                                                            </div>
                                                        </TableCell>
                                                        <TableCell className="text-right font-medium">
                                                            {formatCurrency(stock.close_price, stock.currency)}
                                                        </TableCell>
                                                        <TableCell className="text-right">
                                                            {stock.daily_return !== null ? (
                                                                <span
                                                                    className={`inline-flex items-center text-xs font-semibold ${
                                                                        isPositive
                                                                            ? 'text-emerald-600 dark:text-emerald-400'
                                                                            : 'text-rose-600 dark:text-rose-400'
                                                                    }`}
                                                                >
                                                                    {isPositive ? `+${stock.daily_return}%` : `${stock.daily_return}%`}
                                                                </span>
                                                            ) : (
                                                                '—'
                                                            )}
                                                        </TableCell>
                                                        <TableCell className="text-right font-mono text-xs text-muted-foreground">
                                                            {formatCurrency(stock.sma_20, stock.currency)} / {formatCurrency(stock.sma_50, stock.currency)}
                                                        </TableCell>
                                                        <TableCell className="text-right font-medium">
                                                            {formatBillions(stock.free_cash_flow, stock.currency)}
                                                        </TableCell>
                                                        <TableCell className="text-right font-semibold">
                                                            {stock.roe !== null ? `${stock.roe}%` : '—'}
                                                        </TableCell>
                                                        <TableCell className="text-right font-mono text-xs text-muted-foreground">
                                                            {stock.latest_trade_date ?? '—'}
                                                        </TableCell>
                                                    </TableRow>
                                                );
                                            })
                                        )}
                                    </TableBody>
                                </Table>
                            </div>
                        </CardContent>
                    </Card>
                </div>
            </div>
        </AppLayout>
    );
}
