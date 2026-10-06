"""
Registers the warehouse tables as Superset datasets through Superset's REST API.
Run by the superset-bootstrap service once the Superset server is healthy; credentials
and the server address come from the container environment.

Safe to run again: tables that are already registered are skipped.
"""
import os
import sys

import requests

SUPERSET_URL = os.getenv("SUPERSET_URL", "http://localhost:8088")
DATABASE_NAME = "AFIVE Warehouse"

# Superset reads the curated layers only. All metric logic stays in dbt.
DATASETS = [
    ("gold", "mart_valuation_screener"),
    ("gold", "fact_quarterly_financials"),
    ("gold", "fact_daily_market_valuation"),
    ("gold", "dim_company"),
    ("gold", "agg_industry_benchmarks"),
    ("ops", "obs_filing_coverage"),
    ("ops", "obs_restatements"),
    ("silver", "silver_financial_statements_scd2"),
]

def main() -> int:
    session = requests.Session()

    login = session.post(f"{SUPERSET_URL}/api/v1/security/login", json={
        "username": os.environ["SUPERSET_ADMIN_USER"],
        "password": os.environ["SUPERSET_ADMIN_PASSWORD"],
        "provider": "db",
        "refresh": True,
    }, timeout=30)
    login.raise_for_status()
    session.headers["Authorization"] = f"Bearer {login.json()['access_token']}"

    csrf = session.get(f"{SUPERSET_URL}/api/v1/security/csrf_token/", timeout=30)
    csrf.raise_for_status()
    session.headers["X-CSRFToken"] = csrf.json()["result"]
    session.headers["Referer"] = SUPERSET_URL

    databases = session.get(f"{SUPERSET_URL}/api/v1/database/", params={"q": "(page_size:100)"}, timeout=30)
    databases.raise_for_status()
    database_id = next(
        (d["id"] for d in databases.json()["result"] if d["database_name"] == DATABASE_NAME),
        None,
    )
    if database_id is None:
        print(f"Database '{DATABASE_NAME}' is not registered; has the superset-init container finished?")
        return 1

    existing = session.get(f"{SUPERSET_URL}/api/v1/dataset/", params={"q": "(page_size:500)"}, timeout=30)
    existing.raise_for_status()
    registered = {(d.get("schema"), d["table_name"]) for d in existing.json()["result"]}
    ids_by_table = {d["table_name"]: (d["id"], d.get("schema")) for d in existing.json()["result"]}

    failures = 0
    for schema, table in DATASETS:
        if (schema, table) in registered:
            print(f"exists   {schema}.{table}")
            continue

        # A table that moved schema keeps its dataset, so charts built on it survive
        if table in ids_by_table:
            dataset_id, old_schema = ids_by_table[table]
            moved = session.put(f"{SUPERSET_URL}/api/v1/dataset/{dataset_id}", json={"schema": schema}, timeout=60)
            if moved.ok:
                print(f"moved    {old_schema}.{table} -> {schema}.{table}")
            else:
                failures += 1
                print(f"FAILED   moving {table}: {moved.status_code} {moved.text[:200]}")
            continue

        response = session.post(f"{SUPERSET_URL}/api/v1/dataset/", json={
            "database": database_id,
            "schema": schema,
            "table_name": table,
        }, timeout=60)
        if response.ok:
            print(f"created  {schema}.{table}")
        else:
            failures += 1
            print(f"FAILED   {schema}.{table}: {response.status_code} {response.text[:200]}")

    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main())
