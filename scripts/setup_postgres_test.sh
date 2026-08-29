#!/usr/bin/env bash
# gdash — provision a Postgres role and database for the opt-in live suite.
#
#   sudo scripts/setup_postgres_test.sh          # create
#   sudo scripts/setup_postgres_test.sh --drop   # remove everything it made
#
# Creates role "gdash_test" with a randomly generated password and a database
# "gdash_test" it owns. The password is generated here, written to a 0600 file
# owned by YOU (not root), and never enters the repository -- CLAUDE.md keeps
# credentials out of records, argv, commits and fixtures, and a setup script
# is not an exception.
#
# Touches nothing else: no pg_hba edits, no config changes, no restarts. If
# local password auth over 127.0.0.1 is not already permitted, this reports
# that and stops rather than rewriting your server's authentication.

set -euo pipefail

ROLE="gdash_test"
DBNAME="gdash_test"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "run me with sudo: sudo $0 ${1:-}" >&2
    exit 2
fi

# The invoking human, so the credentials file is theirs rather than root's.
REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    echo "could not identify the invoking user (SUDO_USER is unset)." >&2
    echo "run this as: sudo $0" >&2
    exit 2
fi
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
ENV_FILE="$REAL_HOME/.config/gdash/pg_test.env"

psql_super() { sudo -u postgres psql -v ON_ERROR_STOP=1 -qtAX "$@"; }

if ! command -v psql >/dev/null 2>&1; then
    echo "psql not found on PATH." >&2
    exit 1
fi
if ! sudo -u postgres psql -qtAXc 'select 1' >/dev/null 2>&1; then
    echo "cannot reach Postgres as the 'postgres' superuser." >&2
    echo "is the server running, and does the 'postgres' OS account exist?" >&2
    exit 1
fi

# ------------------------------------------------------- collation preflight
# After a glibc upgrade, Postgres refuses CREATE DATABASE because the template
# databases record the OLD collation version. That is a property of this
# server, not of gdash -- every CREATE DATABASE on it is blocked until the
# templates are refreshed.
collation_mismatch() {
    local db="$1"
    local out
    out="$(psql_super -c "select 1 from pg_database where datname = '${db}' and datcollversion is distinct from pg_database_collation_actual_version(oid)" 2>/dev/null || true)"
    [[ "$out" == "1" ]]
}

STALE=()
for db in template1 template0 postgres; do
    if collation_mismatch "$db"; then STALE+=("$db"); fi
done

if [[ ${#STALE[@]} -gt 0 && "${1:-}" != "--fix-collation" && "${1:-}" != "--drop" ]]; then
    cat >&2 <<MSG

This server's template databases record an older collation version than the
operating system now provides (a glibc upgrade). Postgres refuses CREATE
DATABASE until that is reconciled, so this script cannot continue.

  affected: ${STALE[*]}

Re-run with --fix-collation to refresh JUST those system databases:

    sudo $0 --fix-collation

That is safe for them: template0, template1 and postgres hold catalog data
only, so there are no user indexes whose sort order could have changed.

READ THIS BEFORE YOU DO ANYTHING ELSE, because it is bigger than gdash:
the same glibc change affects YOUR OWN databases. Refreshing a collation
version only updates the recorded number -- it does NOT re-sort anything. Any
existing database with text indexes or collation-aware constraints may now
have indexes ordered by the old locale rules. The correct remedy there is
REINDEX (or at minimum REINDEX on text/varchar indexes and unique
constraints) BEFORE running ALTER DATABASE ... REFRESH COLLATION VERSION on
it. This script deliberately touches none of your databases.

To see which of your databases are affected:

    sudo -u postgres psql -c "select datname, datcollversion, \
      pg_database_collation_actual_version(oid) as actual from pg_database \
      where datcollversion is distinct from pg_database_collation_actual_version(oid);"

MSG
    exit 1
fi

if [[ "${1:-}" == "--fix-collation" ]]; then
    for db in "${STALE[@]}"; do
        echo "refreshing collation version on ${db} (catalog-only system database) ..."
        psql_super -c "alter database ${db} refresh collation version;"
    done
    if [[ ${#STALE[@]} -eq 0 ]]; then
        echo "no system-database collation mismatch to fix"
    fi
    echo "system templates reconciled; continuing with setup"
    echo
fi

# ---------------------------------------------------------------- teardown
if [[ "${1:-}" == "--drop" ]]; then
    echo "dropping database $DBNAME and role $ROLE ..."
    psql_super -c "drop database if exists ${DBNAME};"
    psql_super -c "drop role if exists ${ROLE};"
    if [[ -f "$ENV_FILE" ]]; then
        rm -f "$ENV_FILE"
        echo "removed $ENV_FILE"
    fi
    echo "done. nothing of gdash's remains in this server."
    exit 0
fi

# ---------------------------------------------------------------- create
# Generated here, seen by you, never committed.
PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
if [[ ${#PASSWORD} -lt 16 ]]; then
    echo "could not generate a password" >&2
    exit 1
fi

echo "creating role $ROLE ..."
if [[ "$(psql_super -c "select 1 from pg_roles where rolname = '${ROLE}'")" == "1" ]]; then
    echo "  role exists; resetting its password"
    psql_super -c "alter role ${ROLE} with login password '${PASSWORD}';"
else
    psql_super -c "create role ${ROLE} with login password '${PASSWORD}';"
fi

echo "creating database $DBNAME ..."
if [[ "$(psql_super -c "select 1 from pg_database where datname = '${DBNAME}'")" == "1" ]]; then
    echo "  database exists; leaving it in place"
    psql_super -c "alter database ${DBNAME} owner to ${ROLE};"
else
    psql_super -c "create database ${DBNAME} owner ${ROLE};"
fi

# The runner creates and drops its own schema (gdash_spike) inside this
# database, so ownership is the only privilege it needs.
psql_super -d "$DBNAME" -c "grant all on database ${DBNAME} to ${ROLE};"

# ---------------------------------------------------------------- verify
echo "verifying that $ROLE can connect over 127.0.0.1 ..."
if ! PGPASSWORD="$PASSWORD" psql -h 127.0.0.1 -U "$ROLE" -d "$DBNAME" -qtAXc 'select 1' >/dev/null 2>&1; then
    echo
    echo "The role and database were created, but a password connection over" >&2
    echo "127.0.0.1 was refused. That is a pg_hba.conf policy question, and this" >&2
    echo "script deliberately does not rewrite your authentication config." >&2
    echo
    echo "Typically pg_hba.conf needs a line like:" >&2
    echo "    host    ${DBNAME}    ${ROLE}    127.0.0.1/32    scram-sha-256" >&2
    echo "followed by:  sudo systemctl reload postgresql" >&2
    exit 1
fi
echo "  connection ok"

# ---------------------------------------------------------------- hand off
install -d -m 700 -o "$REAL_USER" -g "$REAL_USER" "$(dirname "$ENV_FILE")"
cat > "$ENV_FILE" <<ENV
# gdash live-Postgres test credentials. Generated $(date -Iseconds).
# Delete with: sudo scripts/setup_postgres_test.sh --drop
export GDASH_POSTGRES_TEST=1
export GDASH_PG_HOST=127.0.0.1
export GDASH_PG_PORT=5432
export GDASH_PG_DB=${DBNAME}
export GDASH_PG_USER=${ROLE}
export GDASH_PG_PASSWORD='${PASSWORD}'
ENV
chown "$REAL_USER:$REAL_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo
echo "Ready. Credentials written to (0600, owned by $REAL_USER):"
echo "    $ENV_FILE"
echo
echo "Run the live suite as yourself -- NOT with sudo:"
echo
echo "    source $ENV_FILE"
echo "    tests/run_postgres.sh"
echo
echo "To remove the role, the database and that file again:"
echo "    sudo scripts/setup_postgres_test.sh --drop"
