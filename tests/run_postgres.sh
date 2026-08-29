#!/usr/bin/env bash
# gdash — live Postgres runner. OPT-IN, never part of the hermetic suite.
#
#   GDASH_POSTGRES_TEST=1 tests/run_postgres.sh
#
# Connection details come from the environment; nothing is committed:
#   GDASH_PG_HOST (default 127.0.0.1)   GDASH_PG_PORT (default 5432)
#   GDASH_PG_DB   (default gdash_test)  GDASH_PG_USER / GDASH_PG_PASSWORD
#
# It proves the one thing the fixture seam cannot: that the SAME refresh path
# carries money exactly when the rows come from a real server, where numeric
# arrives as a string over the wire.

set -uo pipefail

if [[ "${GDASH_POSTGRES_TEST:-0}" != "1" ]]; then
    echo "skipped: set GDASH_POSTGRES_TEST=1 to run the live Postgres suite"
    exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"

PGHOST="${GDASH_PG_HOST:-127.0.0.1}"
PGPORT="${GDASH_PG_PORT:-5432}"
PGDB="${GDASH_PG_DB:-gdash_test}"
PGUSER="${GDASH_PG_USER:-}"
PGPASSWORD="${GDASH_PG_PASSWORD:-}"

if [[ -z "$PGUSER" ]]; then
    echo "GDASH_PG_USER is required" >&2
    exit 2
fi
export PGPASSWORD

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-pg-XXXXXX")"
ROOT="$SCRATCH/root"
mkdir -p "$ROOT/lib/dashboards/sales" "$ROOT/etc" "$ROOT/cache" "$ROOT/log" "$ROOT/run"
cp dashboards/sales/draft.json "$ROOT/lib/dashboards/sales/draft.json"

# numeric(14,2) is the shape design §4 is about: pg returns it as a STRING to
# avoid float loss, and gdash consumes that string directly into minor units.
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -v ON_ERROR_STOP=1 <<'SQL'
drop schema if exists gdash_spike cascade;
create schema gdash_spike;
create table gdash_spike.orders (
    region text not null,
    month  text not null,
    amount numeric(14,2) not null
);
insert into gdash_spike.orders values
    ('west','2026-01',1250.75),
    ('west','2026-02',900.25),
    ('west','2026-03',1100.00),
    ('east','2026-01',640.10),
    ('east','2026-02',725.90),
    ('north','2026-01',310.05);
SQL
if [[ $? -ne 0 ]]; then echo "could not seed the test schema" >&2; rm -rf "$SCRATCH"; exit 1; fi

# The connection profile is a 0600 file outside the repo, with real values
# supplied at run time. Nothing here is committed.
umask 077
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse": { "kind": "postgres", "host": "$PGHOST", "port": $PGPORT,
                 "database": "$PGDB", "user": "$PGUSER", "password": "$PGPASSWORD" } }
JSON
chmod 600 "$ROOT/etc/connections.json"

# Point the dataset at the live schema instead of the fixture's table name.
python3 - "$ROOT" <<'PY'
import json,sys
p=sys.argv[1]+'/lib/dashboards/sales/draft.json'
d=json.load(open(p))
d['datasets']['orders']['sql']="select region, month, amount from gdash_spike.orders"
json.dump(d,open(p,'w'),indent=2)
PY

pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }

out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales 2>&1)"
rc=$?
echo "$out"
ok "refresh from live Postgres succeeds" "$rc" "0"

# The money assertions: exact minor units, not floats.
total="$("$GBASIC" tests/pg_sum.bas "$ROOT/cache/sales/draft/orders.db" '*' 2>&1)"
ok "sum over live data is exact minor units" "$total" "492705"

west="$("$GBASIC" tests/pg_sum.bas "$ROOT/cache/sales/draft/orders.db" west 2>&1)"
ok "param-filtered sum over live data" "$west" "325100"

# A value with more decimals than the column scale must be REFUSED, not
# rounded, even coming from a real numeric column.
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -q -c \
    "alter table gdash_spike.orders alter column amount type numeric(14,4);
     insert into gdash_spike.orders values ('west','2026-04',12.3456);" >/dev/null 2>&1
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1
ok "excess decimals from a live column are refused" "$?" "1"

after="$("$GBASIC" tests/pg_sum.bas "$ROOT/cache/sales/draft/orders.db" '*' 2>&1)"
ok "rejected refresh left the previous data intact" "$after" "492705"

psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -q -c "drop schema gdash_spike cascade;" >/dev/null 2>&1
rm -rf "$SCRATCH"
echo "postgres: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
