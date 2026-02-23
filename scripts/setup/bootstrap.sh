#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh
# Runs all Snowflake infrastructure scripts in order for a target environment.
#
# Usage:
#   ./scripts/setup/bootstrap.sh --env dev
#   ./scripts/setup/bootstrap.sh --env prod --account myorg-myaccount
#
# Prerequisites:
#   - SnowSQL installed and in PATH
#   - .env file populated (copy from .env.example)
#   - ACCOUNTADMIN credentials available (prompted for on first run)
#
# The script uses SnowSQL's key-pair authentication via environment variables.
# Set SNOWSQL_PRIVATE_KEY_PATH in your environment before running.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ENV="dev"
SNOWFLAKE_ACCOUNT=""
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

# ---------------------------------------------------------------------------
# Load .env if present
# ---------------------------------------------------------------------------
if [ -f ".env" ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

SNOWFLAKE_ACCOUNT="${SNOWFLAKE_ACCOUNT:-${SNOWFLAKE_ACCOUNT:-}}"

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
# SnowSQL wrapper function
# ---------------------------------------------------------------------------
run_sql() {
    local script_path="$1"
    local role="${2:-ACCOUNTADMIN}"

    log_info "Running: ${script_path} (role: ${role})"

    if [ "${DRY_RUN}" = true ]; then
        log_warn "[DRY RUN] Would execute: ${script_path}"
        return 0
    fi

    snowsql \
        -a "${SNOWFLAKE_ACCOUNT}" \
        -r "${role}" \
        -f "${script_path}" \
        --option exit_on_error=true \
        --option variable_substitution=true \
        2>&1 | tee -a "logs/bootstrap_${ENV}_$(date +%Y%m%d).log"

    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        log_error "Script failed: ${script_path}"
        exit 1
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
run_sql "infrastructure/snowflake/account_setup/01_databases.sql"    "SYSADMIN"
run_sql "infrastructure/snowflake/account_setup/02_warehouses.sql"   "SYSADMIN"
run_sql "infrastructure/snowflake/account_setup/03_roles.sql"        "SECURITYADMIN"
run_sql "infrastructure/snowflake/account_setup/04_users.sql"        "USERADMIN"
run_sql "infrastructure/snowflake/account_setup/05_network_policies.sql" "SECURITYADMIN"

log_info "=== PHASE 2: Security Controls ==="
run_sql "infrastructure/snowflake/security/01_object_tags.sql"           "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/security/02_data_classification.sql"   "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/security/03_column_masking_policies.sql" "SECURITYADMIN"
run_sql "infrastructure/snowflake/security/04_row_access_policies.sql"   "ACCOUNTADMIN"

log_info "=== PHASE 3: Monitoring ==="
run_sql "infrastructure/snowflake/monitoring/01_resource_monitors.sql"   "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/monitoring/02_audit_logging.sql"       "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/monitoring/03_alerts.sql"              "ACCOUNTADMIN"

log_info "=== PHASE 4: Integrations ==="
run_sql "infrastructure/snowflake/integrations/01_storage_integration_s3.sql"  "ACCOUNTADMIN"
run_sql "infrastructure/snowflake/integrations/02_external_stages.sql"         "SYSADMIN"
run_sql "infrastructure/snowflake/integrations/03_sqlserver_integration.sql"   "SYSADMIN"

log_info "=== PHASE 5: Backup/DR Config ==="
run_sql "infrastructure/snowflake/backup/01_time_travel_config.sql"   "SYSADMIN"
# Note: replication requires a secondary account — run manually
# run_sql "infrastructure/snowflake/backup/02_replication.sql"        "ACCOUNTADMIN"

log_info ""
log_info "=== Bootstrap Complete ==="
log_info "Next steps:"
log_info "  1. Register RSA public keys for service accounts (04_users.sql)"
log_info "  2. Update S3 bucket name and IAM role ARN in integrations (01_storage_integration_s3.sql)"
log_info "  3. Confirm Fivetran/ADF connections are live"
log_info "  4. Run dbt deps && dbt run to validate the full pipeline"
log_info "  5. Apply row access and masking policies: powerbi/row_level_security/rls_snowflake_setup.sql"
