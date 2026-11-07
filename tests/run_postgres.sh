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
source "$HERE/gsql_owners.sh"
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
# avoid float loss, and G-SQL reads that string into money exactly.
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
create table gdash_spike.regions (
    region  text not null,
    label   text not null,
    manager text not null
);
insert into gdash_spike.regions values
    ('west','West','Ada Okonjo'),
    ('east','East','Bo Lindqvist'),
    ('north','North','Ada Okonjo');
SQL
if [[ $? -ne 0 ]]; then echo "could not seed the test schema" >&2; wait_for_gsql_owners "$SCRATCH"; rm -rf "$SCRATCH"; exit 1; fi

# The connection profile is a 0600 file outside the repo, with real values
# supplied at run time. Nothing here is committed.
umask 077
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse":  { "kind": "postgres", "host": "$PGHOST", "port": $PGPORT,
                  "database": "$PGDB", "user": "$PGUSER", "password": "$PGPASSWORD" },
  "regionbook": { "kind": "postgres", "host": "$PGHOST", "port": $PGPORT,
                  "database": "$PGDB", "user": "$PGUSER", "password": "$PGPASSWORD" } }
JSON
chmod 600 "$ROOT/etc/connections.json"

# Point the dataset at the live schema instead of the fixture's table name.
python3 - "$ROOT" <<'PY'
import json,sys
p=sys.argv[1]+'/lib/dashboards/sales/draft.json'
d=json.load(open(p))
d['datasets']['orders']['sql']="select region, month, amount from gdash_spike.orders"
d['datasets']['regions']['sql']="select region, label, manager from gdash_spike.regions"
json.dump(d,open(p,'w'),indent=2)
PY

pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }

out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales 2>&1)"
rc=$?
echo "$out"
ok "refresh from live Postgres succeeds" "$rc" "0"

# The money assertions: exact money, not floats. pg returns numeric as text,
# and G-SQL stores that text as money in the column's currency (GDASH-20).
total="$("$GBASIC" tests/pg_sum.bas "$ROOT/cache/sales/draft/data.gsql" '*' 2>&1)"
ok "sum over live data is exact money" "$total" "4927.050000"

west="$("$GBASIC" tests/pg_sum.bas "$ROOT/cache/sales/draft/data.gsql" west 2>&1)"
ok "param-filtered sum over live data" "$west" "3251.000000"

# Two datasets from the same live server, joined in one visual query with no
# schema prefix, summing money across the join. The fixture seam can prove the
# join; only this proves it over rows that arrived as strings from pg.
mgr="$("$GBASIC" tests/pg_join.bas "$ROOT/cache/sales/draft/data.gsql" 2>&1)"
ok "money sums exactly across a two-dataset join over live data" "$mgr" "Ada Okonjo=3561.050000"

# A second refresh of unchanged live data must not bump the version, or every
# open tab reloads on a timer to see the same numbers.
v1="$(cat "$ROOT/cache/sales/draft/version")"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales orders 2>&1)"
case "$out" in *unchanged*) ok "an unchanged live refetch is recognised" "0" "0" ;;
                        *) ok "an unchanged live refetch is recognised" "$out" "unchanged" ;; esac
ok "and does not bump the version" "$(cat "$ROOT/cache/sales/draft/version")" "$v1"

# D4a: a value finer than the display scale is STORED exactly, and rounded
# only when shown. 12.3456 from a numeric(14,4) column used to fail the
# refresh, because integer minor units at scale 2 had nowhere to put it.
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -q -c \
    "alter table gdash_spike.orders alter column amount type numeric(20,8);
     insert into gdash_spike.orders values ('west','2026-04',12.3456);" >/dev/null 2>&1
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1
ok "a live value finer than the display scale refreshes" "$?" "0"
fine="$("$GBASIC" tests/pg_sum.bas "$ROOT/cache/sales/draft/data.gsql" '*' 2>&1)"
ok "and is summed at its true value" "$fine" "4939.395600"

# What money cannot hold is still REFUSED, not rounded: an eighth decimal of
# USD, from a real numeric column.
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -q -c \
    "insert into gdash_spike.orders values ('east','2026-04',0.00000001);" >/dev/null 2>&1
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1
ok "a live value USD cannot store is refused" "$?" "1"

after="$("$GBASIC" tests/pg_sum.bas "$ROOT/cache/sales/draft/data.gsql" '*' 2>&1)"
ok "rejected refresh left the previous data intact" "$after" "4939.395600"

psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -q -c "drop schema gdash_spike cascade;" >/dev/null 2>&1
wait_for_gsql_owners "$SCRATCH"; rm -rf "$SCRATCH"
echo "postgres: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
