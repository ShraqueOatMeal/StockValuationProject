FROM apache/superset:6.0.0

USER root

# The official image ships without database drivers; add the PostgreSQL one
RUN . /app/.venv/bin/activate && uv pip install --no-cache-dir psycopg2-binary

USER superset
