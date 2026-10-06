import os
from urllib.parse import quote_plus

# Signs session cookies and encrypts stored database credentials. Required: Superset
# refuses to start without it, and there is deliberately no default.
SECRET_KEY = os.environ["SUPERSET_SECRET_KEY"]

# Superset's own metadata database (separate from the afive_dw warehouse)
SQLALCHEMY_DATABASE_URI = (
    f"postgresql+psycopg2://superset:{quote_plus(os.environ['SUPERSET_DB_PASSWORD'])}"
    f"@{os.getenv('SUPERSET_DB_HOST', 'postgres')}:5432/superset"
)

FEATURE_FLAGS = {
    # Phase 2 (embedding dashboards in the Laravel app) turns this on together with the
    # guest-token settings below
    "EMBEDDED_SUPERSET": False,
}

# Results cache. The gold tables change once a day after the Airflow run, so an hour is
# short enough to stay fresh and long enough to make dashboards feel instant.
CACHE_DEFAULT_TIMEOUT = 3600
DATA_CACHE_CONFIG = {
    "CACHE_TYPE": "SimpleCache",
    "CACHE_DEFAULT_TIMEOUT": CACHE_DEFAULT_TIMEOUT,
}

# Analysts explore through charts and SQL Lab against a read-only role; cap result sizes
ROW_LIMIT = 10000
SQL_MAX_ROW = 50000

# --- Phase 2: embedded dashboards -------------------------------------------------
# Uncomment when embedding. The guest-token secret must be its own value, never the
# SECRET_KEY, and framing is allowed for the Laravel origin only rather than everyone.
#
# FEATURE_FLAGS["EMBEDDED_SUPERSET"] = True
# GUEST_ROLE_NAME = "Gamma"
# GUEST_TOKEN_JWT_SECRET = os.environ["SUPERSET_GUEST_TOKEN_SECRET"]
# GUEST_TOKEN_JWT_EXP_SECONDS = 300
# TALISMAN_CONFIG = {
#     "content_security_policy": {"frame-ancestors": [os.environ["APP_ORIGIN"]]},
#     "force_https": False,
# }
# ENABLE_CORS = True
# CORS_OPTIONS = {"supports_credentials": True, "origins": [os.environ["APP_ORIGIN"]]}
