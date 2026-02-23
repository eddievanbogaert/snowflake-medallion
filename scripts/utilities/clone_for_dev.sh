#!/usr/bin/env bash
# =============================================================================
# clone_for_dev.sh
# Creates a zero-copy Snowflake clone of a production schema or database
# into DEV_DB for isolated developer testing.
#
# Usage:
#   ./scripts/utilities/clone_for_dev.sh --schema FOUNDATION_DB.CUSTOMERS
#   ./scripts/utilities/clone_for_dev.sh --database ANALYTICS_DB
#   ./scripts/utilities/clone_for_dev.sh --schema FOUNDATION_DB.CUSTOMERS --name my_sprint
#
# The clone is a zero-copy snapshot (no storage cost until data diverges).
# Use 'drop_dev_clone.sh' or manually DROP the schema/database when done.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET_TYPE=""
TARGET_NAME=""
CLONE_SUFFIX=""
SNOWFLAKE_ACCOUNT="${SNOWFLAKE_ACCOUNT:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --schema)    TARGET_TYPE="SCHEMA";   TARGET_NAME="$2"; shift 2 ;;
        --database)  TARGET_TYPE="DATABASE"; TARGET_NAME="$2"; shift 2 ;;
        --name)      CLONE_SUFFIX="$2";      shift 2 ;;
        --account)   SNOWFLAKE_ACCOUNT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [ -z "$TARGET_TYPE" ] || [ -z "$TARGET_NAME" ]; then
    echo "Usage: $0 --schema|--database <name> [--name <suffix>]"
    exit 1
fi

# Derive developer username from git config or system user
DEV_USER="${CLONE_SUFFIX:-$(git config user.email 2>/dev/null | cut -d@ -f1 | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_')}"
DEV_USER="${DEV_USER:-${USER:-dev}}"

TIMESTAMP=$(date +%Y%m%d_%H%M)
CLONE_NAME="DEV_${DEV_USER^^}_${TARGET_NAME##*.}_${TIMESTAMP}"

echo "Creating zero-copy clone..."
echo "  Source : ${TARGET_TYPE} ${TARGET_NAME}"
echo "  Target : DEV_DB.${CLONE_NAME} (if schema) or ${CLONE_NAME} (if database)"
echo ""

# Build and execute the SQL
if [ "$TARGET_TYPE" = "SCHEMA" ]; then
    SQL="
        USE ROLE DATA_ENGINEER_ROLE;
        CREATE SCHEMA IF NOT EXISTS DEV_DB.${CLONE_NAME}
            CLONE ${TARGET_NAME}
            DATA_RETENTION_TIME_IN_DAYS = 0;
        SELECT 'Clone created: DEV_DB.${CLONE_NAME}' AS result;
    "
else
    SQL="
        USE ROLE DATA_ENGINEER_ROLE;
        CREATE DATABASE IF NOT EXISTS DEV_${CLONE_NAME}
            CLONE ${TARGET_NAME}
            DATA_RETENTION_TIME_IN_DAYS = 0;
        SELECT 'Clone created: DEV_${CLONE_NAME}' AS result;
    "
fi

if [ -n "${SNOWFLAKE_ACCOUNT}" ]; then
    echo "$SQL" | snowsql -a "${SNOWFLAKE_ACCOUNT}" --option exit_on_error=true
else
    echo "$SQL" | snowsql --option exit_on_error=true
fi

echo ""
echo "Clone ready. Connect with:"
echo "  USE ROLE DATA_ENGINEER_ROLE;"
if [ "$TARGET_TYPE" = "SCHEMA" ]; then
    echo "  USE SCHEMA DEV_DB.${CLONE_NAME};"
else
    echo "  USE DATABASE DEV_${CLONE_NAME};"
fi
echo ""
echo "Remember to drop the clone when done:"
if [ "$TARGET_TYPE" = "SCHEMA" ]; then
    echo "  DROP SCHEMA DEV_DB.${CLONE_NAME};"
else
    echo "  DROP DATABASE DEV_${CLONE_NAME};"
fi
