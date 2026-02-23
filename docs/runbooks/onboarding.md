# Developer Onboarding Guide

Welcome to the Snowflake Medallion data platform. This guide gets a new data engineer
or analyst up and running from zero to their first dbt run.

---

## Prerequisites

Install the following tools on your workstation:

```bash
# macOS (Homebrew)
brew install python@3.11 git snowsql

# Python packages
pip install dbt-snowflake==1.8.* sqlfluff pre-commit
```

| Tool | Version | Notes |
|------|---------|-------|
| Python | 3.11+ | Use `pyenv` to manage versions |
| dbt-snowflake | 1.8.x | See packages.yml for exact constraint |
| SnowSQL | 1.2.x | CLI for running .sql scripts |
| Git | 2.x | |
| pre-commit | latest | Enforces code quality before commit |

---

## Step 1: Get Access

1. Raise a request with the **Platform Team** to be added to the appropriate Azure AD groups:
   - Data Engineers: `SNOWFLAKE_DATA_ENGINEERS`
   - Data Analysts: `SNOWFLAKE_DATA_ANALYSTS`
   - Data Scientists: `SNOWFLAKE_DATA_SCIENTISTS`

2. You will receive an email with your Snowflake login URL. Authenticate using your
   corporate SSO credentials (Azure AD).

3. Your default role will be set to your team's role (e.g. `DATA_ANALYST_ROLE`).
   You can switch roles in Snowsight using the role picker in the top-left.

4. Request access to this GitHub repository via the **Data Platform** team channel.

---

## Step 2: Clone and Configure

```bash
git clone https://github.com/your-org/snowflake-medallion.git
cd snowflake-medallion

# Configure pre-commit hooks
pre-commit install
```

---

## Step 3: Configure dbt

Generate an RSA key pair for your dbt local profile:

```bash
# Generate private key (encrypted)
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out ~/.snowflake/rsa_key.p8

# Extract public key
openssl rsa -in ~/.snowflake/rsa_key.p8 -pubout -out ~/.snowflake/rsa_key.pub

# Get the public key content (strip header/footer/newlines)
cat ~/.snowflake/rsa_key.pub
```

Send the public key to the **Platform Team** to be registered against your Snowflake user.
Then set up your dbt profile:

```bash
mkdir -p ~/.dbt
cp dbt/profiles.yml.example ~/.dbt/profiles.yml
```

Edit `~/.dbt/profiles.yml` and update the `dev` target:
- `account`: your Snowflake account identifier (e.g. `myorg-myaccount`)
- `user`: your Snowflake username (typically `firstname.lastname@mycompany.com`)
- `private_key_path`: path to your RSA key (e.g. `~/.snowflake/rsa_key.p8`)
- `private_key_passphrase`: the passphrase you set when generating the key

Test the connection:

```bash
cd dbt
dbt debug
```

Expected output: `All checks passed!`

---

## Step 4: Install dbt Packages and Run

```bash
cd dbt
dbt deps       # Install dbt packages (dbt_utils, dbt_expectations, etc.)
dbt compile    # Compile all models (no execution)
dbt run --select tag:bronze  # Run bronze models only
dbt test --select tag:bronze # Run bronze tests
```

Your models run in a personal schema: `DEV_DB.DBT_DEV_<your-username>.*`
This is completely isolated from production — you can drop/rebuild freely.

---

## Step 5: Development Workflow

### Working on a model change

```bash
# Create a feature branch
git checkout -b feature/your-feature-name

# Make your changes to models/, macros/, tests/
# Run only the changed model and its downstream dependencies
dbt run --select your_model_name+
dbt test --select your_model_name+

# Check lineage
dbt docs generate && dbt docs serve
```

### Cloning production data for development

For testing with real production data (without modifying prod):

```bash
# Run the zero-copy clone script (creates DEV_DB_<your-name>)
./scripts/utilities/clone_for_dev.sh --schema FOUNDATION_DB.CUSTOMERS
```

### Running all tests locally

```bash
dbt test                    # All tests
dbt test --select tag:silver  # Silver layer only
dbt test --select <model_name>  # Specific model
```

---

## Step 6: Raise a Pull Request

1. Push your branch and open a PR against `main`.
2. The dbt CI workflow runs automatically — `dbt compile`, `dbt run`, and `dbt test`.
3. Assign a peer reviewer from the Platform Team.
4. After approval, the team lead merges to `main`.
5. The production dbt workflow runs automatically at 04:00 UTC.

---

## Useful Commands Reference

```bash
# dbt
dbt run --select my_model         # Run one model
dbt run --select tag:silver+      # Run silver and everything downstream
dbt run --select +my_model        # Run my_model and all its parents
dbt run --full-refresh            # Rebuild all incremental models from scratch
dbt test --store-failures         # Store failed test rows in Snowflake for inspection
dbt snapshot                      # Run SCD2 snapshots
dbt source freshness              # Check source data freshness

# SnowSQL
snowsql -a <account> -u <user>    # Interactive session
snowsql -f path/to/script.sql     # Run a SQL script
```

---

## Contacts

| Role | Contact | Slack Channel |
|------|---------|---------------|
| Platform Team lead | platform-team@mycompany.com | #data-platform |
| Snowflake admin | snowflake-admin@mycompany.com | #data-platform |
| Security incidents | security@mycompany.com | #security-incidents |
| dbt / pipeline issues | — | #data-pipeline-alerts |
