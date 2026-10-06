"""
Seeds the starter Superset dashboards through Superset's REST API.
Run by the superset-bootstrap service after the datasets are registered.

A dashboard that already exists is left alone, so edits made in the Superset UI
survive a restart. Set SUPERSET_REBUILD_DASHBOARDS=1 to rebuild them all from this file,
or to a comma-separated list of slugs (for example pipeline-health) to rebuild only those.

Charts only plot columns that dbt has already calculated; the SQL below is limited to
picking the value for a period (MAX) and scaling it for display.
"""
import json
import os
import sys
import uuid

import requests

SUPERSET_URL = os.getenv("SUPERSET_URL", "http://localhost:8088")
REBUILD = os.getenv("SUPERSET_REBUILD_DASHBOARDS", "0")

def should_rebuild(slug: str) -> bool:
    return REBUILD == "1" or slug in [s.strip() for s in REBUILD.split(",")]

# One fixed colour per series name on every chart, so a company or a measure keeps its
# colour wherever it appears. Hues are a colour-blind-safe categorical set.
BLUE, ORANGE, AQUA, YELLOW = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
LABEL_COLORS = {
    "GOOGL": BLUE, "NOW": ORANGE, "1155.KL": AQUA,
    "Net income": BLUE, "Normalized net income": ORANGE, "Operating cash flow": AQUA,
    "CapEx": BLUE, "D&A": ORANGE, "Maintenance CapEx": AQUA,
    "True owner earnings": BLUE, "Cash owner earnings": ORANGE, "Free cash flow": AQUA,
    "Price": BLUE, "Conservative fair value": ORANGE, "Franchise fair value": AQUA,
    "Conservative": ORANGE, "Franchise": AQUA,
    "P/E (GAAP)": BLUE, "P/E (normalized)": ORANGE,
    "financial": BLUE, "share_count": ORANGE,
}

def metric(label: str, sql: str) -> dict:
    return {"expressionType": "SQL", "sqlExpression": sql, "label": label, "hasCustomLabel": True}

def billions(label: str, column: str) -> dict:
    return metric(label, f"MAX({column}) / 1e9")

def value(label: str, column: str) -> dict:
    return metric(label, f"MAX({column})")

def time_filter(column: str, time_range: str = "No filter") -> dict:
    return {
        "clause": "WHERE", "expressionType": "SIMPLE", "subject": column,
        "operator": "TEMPORAL_RANGE", "comparator": time_range,
    }

def where(sql: str) -> dict:
    return {"clause": "WHERE", "expressionType": "SQL", "sqlExpression": sql}

def line(x_axis: str, metrics: list, y_format: str, groupby: list = None, filters: list = None, y_title: str = "") -> dict:
    return {
        "viz_type": "echarts_timeseries_line",
        "x_axis": x_axis,
        "time_grain_sqla": "P1D",
        "metrics": metrics,
        "groupby": groupby or [],
        "adhoc_filters": [time_filter(x_axis)] + (filters or []),
        "row_limit": 10000,
        "y_axis_format": y_format,
        "y_axis_title": y_title,
        "y_axis_title_margin": 40,
        "x_axis_time_format": "smart_date",
        "markerEnabled": False,
        # A single series is already named by the chart title
        "show_legend": len(metrics) > 1 or bool(groupby),
        "legendOrientation": "top",
        "legendType": "scroll",
        "rich_tooltip": True,
        "tooltipTimeFormat": "%Y-%m-%d",
        "truncateYAxis": False,
        "zoomable": False,
        "color_scheme": "supersetColors",
    }

def bar(x_axis: str, metrics: list, y_format: str, groupby: list = None, filters: list = None,
        stacked: bool = False, temporal: bool = False, time_grain: str = "P1Y") -> dict:
    form = {
        "viz_type": "echarts_timeseries_bar",
        "x_axis": x_axis,
        "metrics": metrics,
        "groupby": groupby or [],
        "adhoc_filters": ([time_filter(x_axis)] if temporal else []) + (filters or []),
        "row_limit": 10000,
        "y_axis_format": y_format,
        "show_legend": bool(groupby) or len(metrics) > 1,
        "legendOrientation": "top",
        "rich_tooltip": True,
        "show_value": not temporal,
        "stack": "Stack" if stacked else None,
        "orientation": "vertical",
        "color_scheme": "supersetColors",
    }
    if temporal:
        form["time_grain_sqla"] = time_grain
        form["x_axis_time_format"] = "%Y"
    else:
        form["x_axis_sort_asc"] = True
    return form

def big_number(x_axis: str, m: dict, number_format: str) -> dict:
    # Latest value with its history as a sparkline
    return {
        "viz_type": "big_number",
        "x_axis": x_axis,
        "time_grain_sqla": "P1D",
        "metric": m,
        "adhoc_filters": [time_filter(x_axis)],
        "y_axis_format": number_format,
        "show_trend_line": True,
        "start_y_axis_at_zero": False,
        "header_font_size": 0.4,
        "subheader_font_size": 0.15,
        "rolling_type": "None",
    }

def big_number_total(m: dict, number_format: str, filters: list = None) -> dict:
    return {
        "viz_type": "big_number_total",
        "metric": m,
        "adhoc_filters": filters or [],
        "y_axis_format": number_format,
        "header_font_size": 0.4,
        "subheader_font_size": 0.15,
    }

def table(columns: list, order_by: str, descending: bool, formats: dict = None, filters: list = None, row_limit: int = 100) -> dict:
    return {
        "viz_type": "table",
        "query_mode": "raw",
        "all_columns": columns,
        "order_by_cols": [json.dumps([order_by, not descending])],
        "adhoc_filters": filters or [],
        "row_limit": row_limit,
        "server_page_length": 25,
        "table_timestamp_format": "%Y-%m-%d",
        "show_cell_bars": False,
        "include_search": True,
        "column_config": {c: {"d3NumberFormat": f} for c, f in (formats or {}).items()},
    }

def pivot(rows: list, columns: list, metrics: list, number_format: str, filters: list = None) -> dict:
    return {
        "viz_type": "pivot_table_v2",
        "groupbyRows": rows,
        "groupbyColumns": columns,
        "metrics": metrics,
        "metricsLayout": "COLUMNS",
        "adhoc_filters": filters or [],
        "row_limit": 10000,
        "aggregateFunction": "Sum",
        "valueFormat": number_format,
        "rowTotals": False,
        "colTotals": False,
        "order_desc": False,
    }

PERCENT = ".1%"

# Each dashboard: rows of (chart name, dataset, grid width out of 12, height, form data).
# A string instead of a tuple list is a section heading.
DASHBOARDS = [
    {
        "title": "Quality of Earnings",
        "slug": "quality-of-earnings",
        "company_filter": {"dataset": "fact_quarterly_financials", "default": "GOOGL"},
        "rows": [
            "Is profit backed by cash?",
            [
                ("Net income vs operating cash flow", "fact_quarterly_financials", 8, 55, line(
                    "period_end_date",
                    [billions("Net income", "net_income"), billions("Normalized net income", "normalized_net_income"),
                     billions("Operating cash flow", "operating_cash_flow")],
                    ",.1f", y_title="Billions")),
                ("Normalized accruals ratio", "fact_quarterly_financials", 4, 55, line(
                    "period_end_date", [value("Normalized accruals ratio", "normalized_accruals_ratio")], PERCENT)),
            ],
            "Reinvestment and owner earnings",
            [
                ("CapEx vs depreciation", "fact_quarterly_financials", 6, 55, line(
                    "period_end_date",
                    [billions("CapEx", "capital_expenditures"), billions("D&A", "depreciation_and_amortization"),
                     billions("Maintenance CapEx", "maintenance_capex")],
                    ",.1f", y_title="Billions")),
                ("Owner earnings vs free cash flow", "fact_quarterly_financials", 6, 55, line(
                    "period_end_date",
                    [billions("True owner earnings", "true_owner_earnings"), billions("Cash owner earnings", "cash_owner_earnings"),
                     billions("Free cash flow", "free_cash_flow")],
                    ",.1f", y_title="Billions")),
            ],
            "DuPont: return on equity = net margin x asset turnover x equity multiplier",
            [
                ("Return on equity (quarterly)", "fact_quarterly_financials", 3, 45, line(
                    "period_end_date", [value("Return on equity", "return_on_equity")], PERCENT)),
                ("Net margin", "fact_quarterly_financials", 3, 45, line(
                    "period_end_date", [value("Net margin", "net_margin")], PERCENT)),
                ("Asset turnover", "fact_quarterly_financials", 3, 45, line(
                    "period_end_date", [value("Asset turnover", "asset_turnover")], ",.3f")),
                ("Equity multiplier", "fact_quarterly_financials", 3, 45, line(
                    "period_end_date", [value("Equity multiplier", "equity_multiplier")], ",.2f")),
            ],
        ],
    },
    {
        "title": "Valuation Over Time",
        "slug": "valuation-over-time",
        "company_filter": {"dataset": "fact_daily_market_valuation", "default": "GOOGL"},
        "rows": [
            [
                ("Price", "fact_daily_market_valuation", 4, 28, big_number(
                    "trade_date", value("Price", "close_price"), ",.2f")),
                ("Conservative fair value", "fact_daily_market_valuation", 4, 28, big_number(
                    "trade_date", value("Conservative fair value", "fair_value_per_share"), ",.2f")),
                ("Franchise fair value", "fact_daily_market_valuation", 4, 28, big_number(
                    "trade_date", value("Franchise fair value", "franchise_fair_value_per_share"), ",.2f")),
            ],
            [
                ("Price vs fair value", "fact_daily_market_valuation", 12, 60, line(
                    "trade_date",
                    [value("Price", "close_price"), value("Conservative fair value", "fair_value_per_share"),
                     value("Franchise fair value", "franchise_fair_value_per_share")],
                    ",.0f", y_title="Per share")),
            ],
            [
                ("Margin of safety", "fact_daily_market_valuation", 6, 50, line(
                    "trade_date",
                    [value("Conservative", "margin_of_safety"), value("Franchise", "franchise_margin_of_safety")],
                    ".0%")),
                ("Price to earnings", "fact_daily_market_valuation", 6, 50, line(
                    "trade_date",
                    [value("P/E (GAAP)", "pe_ratio"), value("P/E (normalized)", "normalized_pe_ratio")],
                    ",.1f")),
            ],
        ],
    },
    {
        "title": "Screener",
        "slug": "screener",
        "rows": [
            [
                ("Companies", "mart_valuation_screener", 12, 62, table(
                    ["ticker", "company_name", "industry", "trade_date", "close_price", "fair_value_per_share",
                     "margin_of_safety", "franchise_fair_value_per_share", "franchise_margin_of_safety",
                     "pe_ratio", "normalized_pe_ratio", "owner_earnings_yield", "fcf_yield",
                     "revenue_yoy_growth", "operating_margin", "return_on_equity", "pe_premium_to_industry_pct"],
                    "margin_of_safety", True,
                    {"margin_of_safety": PERCENT, "franchise_margin_of_safety": PERCENT, "owner_earnings_yield": PERCENT,
                     "fcf_yield": PERCENT, "operating_margin": PERCENT, "return_on_equity": PERCENT,
                     "close_price": ",.2f", "fair_value_per_share": ",.2f", "franchise_fair_value_per_share": ",.2f",
                     "pe_ratio": ",.1f", "normalized_pe_ratio": ",.1f", "revenue_yoy_growth": ",.1f"})),
            ],
            "Ranked",
            [
                ("Margin of safety (conservative)", "mart_valuation_screener", 3, 50, bar(
                    "ticker", [value("Margin of safety", "margin_of_safety")], ".0%")),
                ("Owner earnings yield", "mart_valuation_screener", 3, 50, bar(
                    "ticker", [value("Owner earnings yield", "owner_earnings_yield")], PERCENT)),
                ("Revenue growth, year on year (%)", "mart_valuation_screener", 3, 50, bar(
                    "ticker", [value("Revenue growth", "revenue_yoy_growth")], ",.1f")),
                ("Normalized P/E", "mart_valuation_screener", 3, 50, bar(
                    "ticker", [value("Normalized P/E", "normalized_pe_ratio")], ",.1f")),
            ],
        ],
    },
    {
        "title": "Pipeline Health",
        "slug": "pipeline-health",
        "rows": [
            [
                ("Quarters in the warehouse", "obs_filing_coverage", 3, 28, big_number_total(
                    metric("Quarters", "SUM(CASE WHEN is_missing THEN 0 ELSE 1 END)"), ",d")),
                ("Missing quarters", "obs_filing_coverage", 3, 28, big_number_total(
                    metric("Missing quarters", "SUM(CASE WHEN is_missing THEN 1 ELSE 0 END)"), ",d")),
                ("Restated financial facts", "obs_restatements", 3, 28, big_number_total(
                    metric("Restatements", "COUNT(*)"), ",d", [where("restatement_type = 'financial'")])),
                ("Average filing lag (days)", "obs_filing_coverage", 3, 28, big_number_total(
                    metric("Filing lag", "AVG(filing_lag_days)"), ",.0f", [where("is_original_filing")])),
            ],
            [
                ("Quarters held per year", "obs_filing_coverage", 12, 32, pivot(
                    ["ticker"], ["fiscal_year"],
                    [metric("Quarters", "SUM(CASE WHEN is_missing THEN 0 ELSE 1 END)")], ",d")),
            ],
            [
                ("Filing lag by quarter (days)", "obs_filing_coverage", 6, 50, line(
                    "quarter_end_date", [metric("Filing lag", "AVG(filing_lag_days)")], ",.0f",
                    groupby=["ticker"], filters=[where("is_original_filing")])),
                ("Restated facts by filing year", "obs_restatements", 6, 50, bar(
                    "restated_on", [metric("Restated facts", "COUNT(*)")], ",d",
                    groupby=["restatement_type"], stacked=True, temporal=True)),
            ],
            [
                ("Latest financial restatements", "obs_restatements", 12, 55, table(
                    ["ticker", "gaap_tag", "period_end_date", "restated_on", "form_type",
                     "previous_amount", "restated_amount", "change_pct"],
                    "restated_on", True,
                    {"previous_amount": ",.0f", "restated_amount": ",.0f", "change_pct": ",.1f"},
                    [where("restatement_type = 'financial'")], row_limit=1000)),
            ],
        ],
    },
]

class Superset:
    def __init__(self):
        self.session = requests.Session()
        login = self.session.post(f"{SUPERSET_URL}/api/v1/security/login", json={
            "username": os.environ["SUPERSET_ADMIN_USER"],
            "password": os.environ["SUPERSET_ADMIN_PASSWORD"],
            "provider": "db",
            "refresh": True,
        }, timeout=30)
        login.raise_for_status()
        self.session.headers["Authorization"] = f"Bearer {login.json()['access_token']}"
        csrf = self.session.get(f"{SUPERSET_URL}/api/v1/security/csrf_token/", timeout=30)
        csrf.raise_for_status()
        self.session.headers["X-CSRFToken"] = csrf.json()["result"]
        self.session.headers["Referer"] = SUPERSET_URL

    def call(self, method: str, path: str, **kwargs) -> dict:
        response = self.session.request(method, f"{SUPERSET_URL}/api/v1/{path}", timeout=60, **kwargs)
        if not response.ok:
            raise RuntimeError(f"{method} {path}: {response.status_code} {response.text[:300]}")
        return response.json()

    def list(self, resource: str) -> list:
        return self.call("GET", f"{resource}/", params={"q": "(page_size:1000)"})["result"]

def build_layout(dashboard: dict, charts: dict) -> dict:
    layout = {
        "DASHBOARD_VERSION_KEY": "v2",
        "ROOT_ID": {"type": "ROOT", "id": "ROOT_ID", "children": ["GRID_ID"]},
        "GRID_ID": {"type": "GRID", "id": "GRID_ID", "children": [], "parents": ["ROOT_ID"]},
        "HEADER_ID": {"type": "HEADER", "id": "HEADER_ID", "meta": {"text": dashboard["title"]}},
    }
    for index, row in enumerate(dashboard["rows"]):
        if isinstance(row, str):
            header_id = f"HEADER-{index}"
            layout[header_id] = {
                "type": "HEADER", "id": header_id, "children": [], "parents": ["ROOT_ID", "GRID_ID"],
                "meta": {"text": row, "headerSize": "SMALL_HEADER", "background": "BACKGROUND_TRANSPARENT"},
            }
            layout["GRID_ID"]["children"].append(header_id)
            continue

        row_id = f"ROW-{index}"
        layout[row_id] = {
            "type": "ROW", "id": row_id, "children": [], "parents": ["ROOT_ID", "GRID_ID"],
            "meta": {"background": "BACKGROUND_TRANSPARENT"},
        }
        layout["GRID_ID"]["children"].append(row_id)
        for name, _dataset, width, height, _form in row:
            chart_id = charts[name]
            component_id = f"CHART-{chart_id}"
            layout[component_id] = {
                "type": "CHART", "id": component_id, "children": [],
                "parents": ["ROOT_ID", "GRID_ID", row_id],
                "meta": {"chartId": chart_id, "width": width, "height": height, "sliceName": name},
            }
            layout[row_id]["children"].append(component_id)
    return layout

def build_metadata(dashboard: dict, charts: dict, datasets: dict) -> dict:
    metadata = {
        "color_scheme": "supersetColors",
        "label_colors": LABEL_COLORS,
        "cross_filters_enabled": True,
        "native_filter_configuration": [],
    }
    company = dashboard.get("company_filter")
    if company:
        # Single-select company filter: these charts plot one company's history, and
        # companies report in different currencies
        metadata["native_filter_configuration"].append({
            "id": f"NATIVE_FILTER-{uuid.uuid4().hex[:12]}",
            "type": "NATIVE_FILTER",
            "filterType": "filter_select",
            "name": "Company",
            "description": "",
            "targets": [{"datasetId": datasets[company["dataset"]], "column": {"name": "ticker"}}],
            "defaultDataMask": {
                "extraFormData": {"filters": [{"col": "ticker", "op": "IN", "val": [company["default"]]}]},
                "filterState": {"value": [company["default"]]},
            },
            "controlValues": {
                "multiSelect": False, "enableEmptyFilter": True, "defaultToFirstItem": False,
                "inverseSelection": False, "searchAllOptions": False,
            },
            "cascadeParentIds": [],
            "scope": {"rootPath": ["ROOT_ID"], "excluded": []},
            "chartsInScope": list(charts.values()),
            "tabsInScope": [],
        })
    return metadata

def main() -> int:
    api = Superset()
    datasets = {d["table_name"]: d["id"] for d in api.list("dataset")}
    existing_dashboards = {d["slug"]: d["id"] for d in api.list("dashboard") if d.get("slug")}
    existing_charts = {c["slice_name"]: c["id"] for c in api.list("chart")}

    for dashboard in DASHBOARDS:
        slug = dashboard["slug"]
        if slug in existing_dashboards and not should_rebuild(slug):
            print(f"exists   dashboard '{dashboard['title']}' (left as it is)")
            continue

        if slug in existing_dashboards:
            dashboard_id = existing_dashboards[slug]
        else:
            dashboard_id = api.call("POST", "dashboard/", json={
                "dashboard_title": dashboard["title"], "slug": slug, "published": True,
            })["id"]

        charts = {}
        for row in dashboard["rows"]:
            if isinstance(row, str):
                continue
            for name, dataset, _width, _height, form in row:
                if dataset not in datasets:
                    print(f"FAILED   chart '{name}': dataset {dataset} is not registered")
                    return 1
                dataset_id = datasets[dataset]
                payload = {
                    "slice_name": name,
                    "viz_type": form["viz_type"],
                    "datasource_id": dataset_id,
                    "datasource_type": "table",
                    "params": json.dumps({**form, "datasource": f"{dataset_id}__table"}),
                    "dashboards": [dashboard_id],
                }
                if name in existing_charts:
                    api.call("PUT", f"chart/{existing_charts[name]}", json=payload)
                    charts[name] = existing_charts[name]
                else:
                    charts[name] = api.call("POST", "chart/", json=payload)["id"]

        # Charts dropped or renamed in this file would otherwise linger on a rebuilt dashboard
        for chart in api.call("GET", f"dashboard/{dashboard_id}/charts")["result"]:
            if chart["id"] not in charts.values():
                api.call("DELETE", f"chart/{chart['id']}")

        api.call("PUT", f"dashboard/{dashboard_id}", json={
            "dashboard_title": dashboard["title"],
            "position_json": json.dumps(build_layout(dashboard, charts)),
            "json_metadata": json.dumps(build_metadata(dashboard, charts, datasets)),
            "published": True,
        })
        print(f"built    dashboard '{dashboard['title']}' with {len(charts)} charts")

    return 0

if __name__ == "__main__":
    sys.exit(main())
