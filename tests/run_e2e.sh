#!/usr/bin/env bash
# gdash end-to-end: the spine over a real HTTP server.
#
# Still hermetic: loopback only, fixture source, no database, no display.
# Driven from the shell because the assertions are about HTTP.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-e2e-XXXXXX")"
ROOT="$SCRATCH/root"
PORT=8780
pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }
has(){ if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3: <$2> not found"; fail=$((fail+1)); fi; }
hasnt(){ if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3: <$2> should be absent"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }

mkdir -p "$ROOT/lib/dashboards/sales" "$ROOT/etc" "$ROOT/cache" "$ROOT/log" "$ROOT/run"
cp dashboards/sales/draft.json "$ROOT/lib/dashboards/sales/draft.json"

# Obviously-fake profile values; the fixture source needs no credentials.
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse": { "kind": "fixture", "path": "fixtures/orders.json" } }
JSON

# A dashboard that does NOT opt into open access, to prove fail-closed.
mkdir -p "$ROOT/lib/dashboards/private"
python3 - "$ROOT" <<'PY'
import json,sys
r=sys.argv[1]
d=json.load(open('dashboards/sales/draft.json'))
d.pop('access',None); d['name']='private'
json.dump(d,open(r+'/lib/dashboards/private/draft.json','w'),indent=2)
PY

echo "--- CLI: validate and refresh ---"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" validate sales 2>&1)"; ok "validate exits 0" "$?" "0"
has "$out" "validates" "validate reports ok"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales 2>&1)"; ok "refresh exits 0" "$?" "0"
has "$out" "version 1" "refresh bumps the version"

echo "--- server ---"
GDASH_ROOT="$ROOT" "$GBASIC" --line-buffered src/gdash_server.bas > "$SCRATCH/server.log" 2>&1 &
SRV=$!
for i in $(seq 1 60); do grep -q "listening" "$SCRATCH/server.log" 2>/dev/null && break; sleep 0.25; done
has "$(cat "$SCRATCH/server.log")" "listening" "server started"

page="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
has "$page" "<svg" "page carries the bar mark as SVG"
has "$page" "gdash-value" "page carries the value mark"
has "$page" '$4,927.05' "value mark shows the exact grand total"
has "$page" "data as of" "page shows data-as-of"
has "$page" 'data-param="region"' "page carries the slicer bound to :region"
has "$page" "<option" "slicer options came from a query over the dataset"
has "$page" "north" "slicer lists a value only the data knows"
has "$page" "EventSource" "page opens an SSE stream"

echo "--- tabs and the table mark (GDASH-1) ---"
has "$page" 'class="gdash-tabs"' "multi-tab record renders a tab bar"
has "$page" 'data-tab="2"' "all three tabs are present"
has "$page" 'data-pane="1" hidden' "non-active panes start hidden"
has "$page" "<table>" "the table mark rendered"
has "$page" "gdashTab" "tab switching is client-side"
# every tab renders server-side in ONE response -- the Trend tab's line chart
# is in the page even though the Overview tab is showing.
has "$page" "trend_by_region" "a hidden tab's visual is already rendered"
has "$page" "justify-content:space-between" "space maps to flex justification"
has "$page" "flex:2 1 0" "a weighted child flexes"
has "$page" "gap:16px" "gap is applied"

echo "--- access fails closed (design §8) ---"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/private")"
ok "record without access:open is refused" "$code" "403"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/nosuch")"
ok "unknown dashboard is 404" "$code" "404"

echo "--- slicer round trip: only binding visuals re-run (design §2) ---"
resp="$(curl -s --max-time 10 -X POST -H 'content-type: application/json' -d '{"region":"east"}' "http://127.0.0.1:$PORT/d/sales/params")"
has "$resp" '"by_month"' "the visual binding :region re-rendered"
hasnt "$resp" '"grand_total"' "the visual that does not bind it stayed put"
has "$resp" "<svg" "the re-rendered fragment is a chart"

west="$(curl -s --max-time 10 -X POST -H 'content-type: application/json' -d '{"region":"west"}' "http://127.0.0.1:$PORT/d/sales/params")"
if [[ "$west" != "$resp" ]]; then echo "  ok   a different param value renders differently"; pass=$((pass+1));
else echo "  FAIL a different param value renders differently"; fail=$((fail+1)); fi

echo "--- SSE carries a refresh notification (design §5) ---"
curl -s -N --max-time 6 "http://127.0.0.1:$PORT/d/sales/events" > "$SCRATCH/sse.txt" &
SSE=$!
sleep 1
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1
sleep 2.5
kill $SSE 2>/dev/null; wait $SSE 2>/dev/null
has "$(cat "$SCRATCH/sse.txt")" "data: refresh" "SSE emitted on the version bump"

echo "--- a failed refresh leaves the dashboard serving old data ---"
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse": { "kind": "fixture", "path": "fixtures/orders_unavailable.json" } }
JSON
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1
ok "failed refresh exits nonzero" "$?" "1"
page2="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
has "$page2" '$4,927.05' "dashboard still shows the previous data"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
rm -rf "$SCRATCH"
[[ -e "$SCRATCH" ]] && { echo "SCRATCH NOT CLEAN"; exit 1; }
echo "scratch clean: $SCRATCH removed"
echo "e2e: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
