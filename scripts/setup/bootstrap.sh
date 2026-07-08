#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh
# Runs all Snowflake infrastructure scripts in order for a target environment.
#
# Usage:
#   ./scripts/setup/bootstrap.sh --env dev
#   ./scripts/setup/bootstrap.sh --env prod --account myorg-myaccount
#
# NOTE on --env: environment separation is by ACCOUNT (see
# docs/architecture/multi_account_architecture.md) — the same scripts run in
# every account. --env only (a) gates the production confirmation prompt and
# (b) names the log file. Point --account at the right environment's account.
#
# Prerequisites:
#   - Snowflake CLI (`snow`) installed and in PATH — https://docs.snowflake.com/en/developer-guide/snowflake-cli
#     (falls back to legacy SnowSQL if `snow` is not found)
#   - .env file populated (copy from .env.example)
#   - ACCOUNTADMIN credentials available (prompted for on first run)
#
# Authentication:
#   - Snowflake CLI: set SNOWFLAKE_USER and SNOWFLAKE_PRIVATE_KEY_PATH in .env
#     (used with a temporary connection), or configure a named connection via
#     `snow connection add` and export SNOWFLAKE_DEFAULT_CONNECTION_NAME.
#   - SnowSQL (legacy): set SNOWSQL_PRIVATE_KEY_PATH before running.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Load .env if present (before arg parsing, so --account overrides .env)
# ---------------------------------------------------------------------------
if [ -f ".env" ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ENV="dev"
SNOWFLAKE_ACCOUNT="${SNOWFLAKE_ACCOUNT:-}"
DRY_RUN=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --env)            ENV="$2";               shift 2 ;;
        --account)        SNOWFLAKE_ACCOUNT="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true;           shift ;;
        --yes)            SKIP_CONFIRM=true;      shift ;;
        *)                echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [ -z "$SNOWFLAKE_ACCOUNT" ]; then
    echo "ERROR: SNOWFLAKE_ACCOUNT is not set. Use --account or set in .env"
    exit 1
fi

# ---------------------------------------------------------------------------
# Colours and logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Confirmation gate
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Snowflake Bootstrap"
echo "  Account  : ${SNOWFLAKE_ACCOUNT}"
echo "  Env      : ${ENV}"
echo "  Dry run  : ${DRY_RUN}"
echo "=========================================="
echo ""

if [ "${SKIP_CONFIRM}" = false ] && [ "${ENV}" = "prod" ]; then
    log_warn "You are about to bootstrap a PRODUCTION Snowflake account."
    read -r -p "Type 'yes I am sure' to continue: " confirmation
    if [ "$confirmation" != "yes I am sure" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# SQL client selection: Snowflake CLI (`snow`) preferred; SnowSQL is legacy.
# ---------------------------------------------------------------------------
if command -v snow >/dev/null 2>&1; then
    SQL_CLIENT="snow"
elif command -v snowsql >/dev/null 2>&1; then
    SQL_CLIENT="snowsql"
    log_warn "Using legacy SnowSQL — consider migrating to Snowflake CLI (snow)."
else
    log_error "Neither 'snow' (Snowflake CLI) nor 'snowsql' found in PATH."
    exit 1
fi

# ---------------------------------------------------------------------------
# SQL execution wrapper
# ---------------------------------------------------------------------------
run_sql() {
    local script_path="$1"
    local role="${2:-ACCOUNTADMIN}"

    log_info "Running: ${script_path} (role: ${role}) via ${SQL_CLIENT}"

    if [ "${DRY_RUN}" = true ]; then
        log_warn "[DRY RUN] Would execute: ${script_path}"
        return 0
    fi

    # The `if !` guard (rather than checking PIPESTATUS afterwards) is required
    # because `set -euo pipefail` would abort before a follow-up check runs.
    if [ "${SQL_CLIENT}" = "snow" ]; then
        # Temporary connection from environment (SNOWFLAKE_USER /
        # SNOWFLAKE_PRIVATE_KEY_PATH come from .env). If you prefer a named
        # connection (`snow connection add`), replace the flags below with
        # `--connection <name>`.
        if ! snow sql \
            --filename "${script_path}" \
            --temporary-connection \
            --account "${SNOWFLAKE_ACCOUNT}" \
            --user "${SNOWFLAKE_USER:?SNOWFLAKE_USER must be set in .env for snow CLI}" \
            --private-key-file "${SNOWFLAKE_PRIVATE_KEY_PATH:?SNOWFLAKE_PRIVATE_KEY_PATH must be set in .env for snow CLI}" \
            --role "${role}" \
            2>&1 | tee -a "logs/bootstrap_${ENV}_$(date +%Y%m%d).log"; then
            log_error "Script failed: ${script_path}"
            exit 1
        fi
    else
        # Legacy SnowSQL. variable_substitution stays OFF: no script uses
        # &vars, and enabling it makes snowsql choke on literal ampersands.
        if ! snowsql \
            -a "${SNOWFLAKE_ACCOUNT}" \
            -r "${role}" \
            -f "${script_path}" \
            --option exit_on_error=true \
            2>&1 | tee -a "logs/bootstrap_${ENV}_$(date +%Y%m%d).log"; then
            log_error "Script failed: ${script_path}"
            exit 1
        fi
    fi
    log_info "Completed: ${script_path}"
}

# ---------------------------------------------------------------------------
# Create log directory
# ---------------------------------------------------------------------------
mkdir -p logs

# ---------------------------------------------------------------------------
# Run scripts in order
# ---------------------------------------------------------------------------
log_info "=== PHASE 1: Account Setup ==="
run_sql "infrastructure/snowflake/account_setup/01_databases.sql"         "SYSADMIN"
run_sql "infrastructure/snowflake/account_setup/02_warehouses.sql"        "SYSADMIN"
run_sql "infrastructure/snowflake/account_setup/03_roles.sql"             "SECURITYADMIN"
run_sql "infrastructure/snowflake/account_setup/04_users.sql"             "USERADMIN"
run_sql "infrastructure/snowflake/account_setup/05_network_policies.sql"  "SECURITYADMIN"
run_sql "infrastructure/snowflake/account_setup/06_password_policies.sql" "ACCOUNTADMIN"   # CIS 1.3/1.4
run_sql "infrastructure/snowflake/account_setup/07_scim_integration.sql"  "ACCOUNTADMIN"   # CIS 1.6
run_sql "infrastructure/snowflake/account_setup/08_authentication_policies.sql" "ACCOUNTADMIN"  # MFA/auth method enforcement

log_info "=== PHASE 2: Security Controls ==="
run_sql "infrastructure/snowflake/security/01_object_tags.sql"                  "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/security/02_data_classification.sql"          "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/security/03_column_masking_policies.sql"      "SECURITYADMIN"
run_sql "infrastructure/snowflake/security/04_row_access_policies.sql"          "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/security/05_managed_access_schemas.sql"       "ACCOUNTADMIN"   # CIS 3.5
run_sql "infrastructure/snowflake/security/07_trust_center.sql"                 "ACCOUNTADMIN"   # Trust Center access grants
# Note: 06_cis_compliance_checks.sql is for auditing, not deployment — run manually
# Note: Trust Center scanner packages (incl. CIS Benchmarks) are enabled in Snowsight — see 07_trust_center.sql

log_info "=== PHASE 3: Monitoring ==="
run_sql "infrastructure/snowflake/monitoring/01_resource_monitors.sql"          "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/monitoring/02_audit_logging.sql"              "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/monitoring/03_alerts.sql"                     "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/monitoring/04_privileged_access_alerts.sql"   "ACCOUNTADMIN"   # CIS 5.3/6.x

log_info "=== PHASE 4: Integrations ==="
run_sql "infrastructure/snowflake/integrations/01_storage_integration_s3.sql"  "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/integrations/02_external_stages.sql"         "SYSADMIN"
run_sql "infrastructure/snowflake/integrations/03_sqlserver_integration.sql"   "SYSADMIN"

log_info "=== PHASE 5: Backup/DR Config ==="
run_sql "infrastructure/snowflake/backup/01_time_travel_config.sql"   "SYSADMIN"
# Note: replication requires a secondary account — run manually
# run_sql "infrastructure/snowflake/backup/02_replication.sql"        "ACCOUNTADMIN"

log_info "=== PHASE 6: Cortex AI Governance ==="
run_sql "infrastructure/snowflake/cortex/00_cortex_governance.sql"    "ACCOUNTADMIN"
# Note: cortex/01-04 (semantic views, search, anomaly ML, document AI) depend
# on dbt-built tables / staged content — run manually after the first dbt run.

log_info ""
log_info "=== Bootstrap Complete ==="
log_info "Next steps:"
log_info "  1. Register RSA public keys for service accounts (04_users.sql)"
log_info "  2. Update S3 bucket name and IAM role ARN in integrations (01_storage_integration_s3.sql)"
log_info "  3. Confirm Fivetran/ADF connections are live"
log_info "  4. Run dbt deps && dbt seed && dbt run to validate the full pipeline"
log_info "  5. Apply row access and masking policies: powerbi/row_level_security/rls_snowflake_setup.sql"
log_info "  6. Configure SCIM in Azure AD (see 07_scim_integration.sql for steps)"
log_info "  7. Verify CIS compliance posture: infrastructure/snowflake/security/06_cis_compliance_checks.sql"
log_info "  8. For multi-account / DR setup: see infrastructure/snowflake/multi_account/"
