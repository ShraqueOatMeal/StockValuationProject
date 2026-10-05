FROM apache/airflow:2.9.3-python3.11

USER airflow

# Copy requirements into the container owned by airflow user
COPY --chown=airflow:root requirements.txt /opt/airflow/requirements.txt

# Install directly into Airflow's user environment
RUN pip install --no-cache-dir -r /opt/airflow/requirements.txt

# dbt lives in its own virtual environment so its dependencies cannot clash with Airflow's
RUN python -m venv /opt/airflow/dbt_venv \
    && /opt/airflow/dbt_venv/bin/pip install --no-cache-dir "dbt-postgres>=1.11,<2"
