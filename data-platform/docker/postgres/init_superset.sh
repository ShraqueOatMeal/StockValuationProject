#!/bin/bash
# Roles and metadata database for Apache Superset. Run by the superset-db-init service on
# every `docker compose up`, connecting to the postgres service over the network.
# It is safe to run again: existing roles only have their passwords reset to match .env.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -v superset_password="$SUPERSET_DB_PASSWORD" \
    -v readonly_password="$WAREHOUSE_READONLY_PASSWORD" \
    -v warehouse_owner="$POSTGRES_USER" <<'SQL'

-- 1. Superset's own metadata (users, charts, dashboards) lives in a separate database,
-- away from the warehouse, Airflow and Laravel tables
SELECT format('CREATE ROLE superset LOGIN PASSWORD %L', :'superset_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'superset') \gexec
SELECT format('ALTER ROLE superset PASSWORD %L', :'superset_password') \gexec

SELECT 'CREATE DATABASE superset OWNER superset'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'superset') \gexec

-- 2. Read-only role Superset uses to query the warehouse: curated layers only, and a
-- statement timeout so an exploratory query cannot hold up Airflow or the web app
SELECT format('CREATE ROLE afive_readonly LOGIN PASSWORD %L', :'readonly_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'afive_readonly') \gexec
SELECT format('ALTER ROLE afive_readonly PASSWORD %L', :'readonly_password') \gexec

ALTER ROLE afive_readonly SET statement_timeout = '15s';

-- dbt creates the ops schema on its first run; create it here too so the grants below
-- work on a database dbt has not built yet
CREATE SCHEMA IF NOT EXISTS ops;

GRANT USAGE ON SCHEMA gold, silver, ops TO afive_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA gold, silver, ops TO afive_readonly;

-- dbt drops and recreates its tables, so future tables need the grant as well
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA gold, silver, ops GRANT SELECT ON TABLES TO afive_readonly', :'warehouse_owner') \gexec
SQL
