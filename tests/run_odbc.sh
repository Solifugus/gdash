#!/usr/bin/env bash
# gdash — the ODBC source, through a real driver manager.
#
#   GDASH_ODBC_TEST=1 tests/run_odbc.sh
#
# Opt-in like the Postgres, LDAP and FHS runners, but CHEAPER THAN ALL OF THEM:
# the SQLite ODBC driver reads a file, so this exercises the real unixODBC path
# with no service to start (finding G9-3). It should be run often.
#
# What it proves that the hermetic suite cannot: that values come back as text
# through a real driver, which is the single fact gdash's money exactness rests
# on when the origin is ODBC.

set -uo pipefail

if [[ "${GDASH_ODBC_TEST:-0}" != "1" ]]; then
    echo "skipped: set GDASH_ODBC_TEST=1 to run the live ODBC suite"
    exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/gsql_owners.sh"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"
DRIVER="${GDASH_ODBC_DRIVER:-SQLite3}"

command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is needed to build the source database" >&2; exit 2; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-odbc-XXXXXX")"
ROOT="$SCRATCH/root"
mkdir -p "$ROOT/etc" "$ROOT/lib/dashboards/sales" "$ROOT/lib/dashboards/viafix" "$ROOT/cache" "$ROOT/log" "$ROOT/run"
trap 'wait_for_gsql_owners "$SCRATCH"; rm -rf "$SCRATCH"' EXIT

pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }
has(){ if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3: <$2> not found"; fail=$((fail+1)); fi; }
hasnt(){ if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3: <$2> should be absent"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }

# The source: a money column with four decimal places, which is where a float
# would lose the last digit.
sqlite3 "$SCRATCH/src.db" "create table orders (region text, month text, amount decimal(19,4));
insert into orders values ('west','2026-01','1250.7500'),('west','2026-02','900.2500'),('east','2026-01','1100.0000');"

# The SAME rows as a fixture, so the two origins can be compared.
cat > "$SCRATCH/orders.json" <<JSON
{ "columns": ["region", "month", "amount"],
  "rows": [["west","2026-01","1250.7500"],["west","2026-02","900.2500"],["east","2026-01","1100.0000"]] }
JSON

python3 - "$ROOT" "$SCRATCH" "$DRIVER" <<'PY'
import json, sys
root, scratch, driver = sys.argv[1], sys.argv[2], sys.argv[3]
base = json.load(open('dashboards/sales/draft.json'))
def dash(name, profile):
    d = json.loads(json.dumps(base))
    d['name'] = name
    d['datasets'] = {'orders': {'profile': profile, 'refresh': 'manual',
                                'sql': 'select region, month, amount from orders',
                                'columns': {'amount': {'type': 'money', 'scale': 2, 'currency': 'USD'}}}}
    d['visuals'] = {'total': {'dataset': 'orders', 'sql': 'select sum(amount) as total from orders',
                              'encoding': {'mark': 'value', 'value': 'total',
                                           'format': 'currency', 'currency': 'USD', 'title': 'Revenue'}}}
    d['controls'] = {}; d['params'] = {}
    d['tabs'] = [{'name': 'T', 'layout': {'vert': [{'visual': 'total'}]}}]
    json.dump(d, open(f'{root}/lib/dashboards/{name}/draft.json', 'w'), indent=2)
dash('sales', 'warehouse')
dash('viafix', 'asfixture')
json.dump({
    'warehouse':  {'kind': 'odbc', 'connection': f'Driver={driver};Database={scratch}/src.db'},
    'asfixture':  {'kind': 'fixture', 'path': f'{scratch}/orders.json'},
    'nodriver':   {'kind': 'odbc', 'connection': 'Driver=NoSuchDriverHere;Database=/tmp/x;PWD=hunter2-must-not-appear'},
    'noconn':     {'kind': 'odbc'},
}, open(f'{root}/etc/connections.json', 'w'), indent=2)
PY

echo "--- the driver manager is really there ---"
chk="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" source check warehouse 2>&1)"
has "$chk" "connected" "gdash connects through the driver manager"
has "$chk" "arrive as: string" "and values arrive as text, which is what money rests on"

echo "--- a refresh through ODBC ---"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales 2>&1)"
has "$out" "version 1" "a dataset refreshes from an ODBC source"
# The staged data is G-SQL now (GDASH-20). The source's decimal(19,4) arrives
# as text and is stored as money, exactly, at USD's six places.
money="$("$GBASIC" tests/stage_query.bas "$ROOT/cache/sales/draft/data.gsql" "select amount from orders order by region, month")"
ok "money lands as exact money" "$money" "1100.000000,1250.750000,900.250000"
meta="$("$GBASIC" tests/stage_query.bas "$ROOT/cache/sales/draft/data.gsql" "select kind || ':' || currency || ':' || cast(scale as text) from _gdash_meta where dataset = 'orders' and column_name = 'amount'")"
ok "with its currency and display scale recorded" "$meta" "money:USD:2"

echo "--- parity: the same rows through a different origin ---"
# The seam's whole claim. If two origins disagree, one of them is lying about
# what the source said, and the money path is where that would show first.
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh viafix >/dev/null 2>&1
fixmoney="$("$GBASIC" tests/stage_query.bas "$ROOT/cache/viafix/draft/data.gsql" "select amount from orders order by region, month")"
ok "ODBC and the fixture source stage identical values" "$money" "$fixmoney"
fixmeta="$("$GBASIC" tests/stage_query.bas "$ROOT/cache/viafix/draft/data.gsql" "select kind || ':' || currency || ':' || cast(scale as text) from _gdash_meta where dataset = 'orders' and column_name = 'amount'")"
ok "and identical column metadata" "$meta" "$fixmeta"

echo "--- credentials ---"
# A connection string carries PWD=. The driver's own message was checked and is
# clean, but a driver is third-party code and the next one may not be, so this
# is asserted rather than assumed.
bad="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales 2>&1)"   # warm, succeeds
python3 - "$ROOT" <<'PY'
import json, sys
p = f'{sys.argv[1]}/lib/dashboards/sales/draft.json'
d = json.load(open(p)); d['datasets']['orders']['profile'] = 'nodriver'
json.dump(d, open(p, 'w'), indent=2)
PY
failed="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales 2>&1)"
has "$failed" "cannot connect to source" "a missing driver fails by name"
hasnt "$failed" "hunter2-must-not-appear" "and the connection string never reaches the message"
hasnt "$(cat "$ROOT/log/audit.log" 2>/dev/null)" "hunter2-must-not-appear" "nor the audit log"

echo "--- a profile that names nothing ---"
python3 - "$ROOT" <<'PY'
import json, sys
p = f'{sys.argv[1]}/lib/dashboards/sales/draft.json'
d = json.load(open(p)); d['datasets']['orders']['profile'] = 'noconn'
json.dump(d, open(p, 'w'), indent=2)
PY
empty="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales 2>&1)"
has "$empty" "neither 'connection' nor 'dsn'" "an odbc profile with no target says so"

echo "--- and the previous data is untouched by a failed refresh ---"
still="$("$GBASIC" tests/stage_query.bas "$ROOT/cache/sales/draft/data.gsql" "select amount from orders order by region, month")"
ok "stale but coherent, as design §3 requires" "$still" "1100.000000,1250.750000,900.250000"

echo "---"
echo "odbc: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
