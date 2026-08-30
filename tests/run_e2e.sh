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
{ "warehouse":  { "kind": "fixture", "path": "fixtures/orders.json" },
  "regionbook": { "kind": "fixture", "path": "fixtures/regions.json" },
  "flaky":      { "kind": "fixture", "path": "fixtures/orders_unavailable.json" } }
JSON

# Repointing one profile at a different fixture is how this run makes a source
# change, go down, and come back.
repoint(){ python3 -c "
import json,sys
c=json.load(open(sys.argv[1]))
c['warehouse']['path']=sys.argv[2]
json.dump(c,open(sys.argv[1],'w'))
" "$ROOT/etc/connections.json" "$1"; }

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

echo "--- two datasets, joined with no schema prefix (design §3) ---"
has "$page" "Ada Okonjo" "a visual joins the second dataset and renders a value only it knows"
has "$page" "orders: data as of" "the status line names the first dataset"
has "$page" "regions: data as of" "and the second, because one line for a dashboard stops being true"

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
# Refetching identical data no longer bumps the version, so the notification
# has to be driven by data that actually moved.
repoint fixtures/orders_moved.json
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales orders >/dev/null 2>&1
sleep 2.5
kill $SSE 2>/dev/null; wait $SSE 2>/dev/null
has "$(cat "$SCRATCH/sse.txt")" "data: refresh" "SSE emitted on the version bump"

echo "--- an unchanged refresh does not bump the version ---"
before_v="$(cat "$ROOT/cache/sales/draft/version")"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales orders 2>&1)"
has "$out" "unchanged" "refetching identical data reports unchanged"
ok "and leaves the version alone" "$(cat "$ROOT/cache/sales/draft/version")" "$before_v"

echo "--- a failed refresh leaves the dashboard serving old data ---"
repoint fixtures/orders_unavailable.json
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1
ok "failed refresh exits nonzero" "$?" "1"
page2="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
has "$page2" '$5,339.65' "dashboard still shows the previous data"
has "$page2" "last refresh failed" "and says the last refresh failed"
has "$page2" "configured to fail" "naming what the source said"

# ---------------------------------------------------------------------------
# The scheduler. GDASH-3 owns publish, so this writes the `current` pointer and
# a snapshot by hand -- the read side is what GDASH-2 implements (brief §2.4).
# ---------------------------------------------------------------------------
echo "--- policy refresh needs a published dashboard (design §3) ---"
python3 "$HERE/e2e_publish.py" "$ROOT"
repoint fixtures/orders.json

out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" schedule 2>&1)"
has "$out" "timed.orders: refreshed" "an interval dataset with no data yet refreshes on the first pass"
has "$out" "timed.regions: refreshed" "so does its hour-long sibling"
hasnt "$out" "sales." "an unpublished dashboard is not scheduled at all"
hasnt "$out" "opened.orders: refreshed" "an on_open dataset waits for someone to open it"
has "$out" "down.orders:" "a failing dataset is reported"
if [[ -f "$ROOT/cache/timed/published/orders.db" ]]; then echo "  ok   published data lands in the published directory"; pass=$((pass+1)); else echo "  FAIL published data lands in the published directory"; fail=$((fail+1)); fi
if [[ -f "$ROOT/cache/timed/draft/orders.db" ]]; then echo "  FAIL a policy refresh must not write the draft directory"; fail=$((fail+1)); else echo "  ok   a policy refresh does not touch the draft directory"; pass=$((pass+1)); fi

echo "--- the interval is honoured, and an unchanged refetch is quiet ---"
v1="$(cat "$ROOT/cache/timed/published/version")"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" schedule 2>&1)"
hasnt "$out" "timed.regions" "the hour-long dataset is not due a second later"
sleep 1.2
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" schedule 2>&1)"
has "$out" "timed.orders: unchanged" "the one-second interval fires again and finds nothing changed"
ok "and the version did not move" "$(cat "$ROOT/cache/timed/published/version")" "$v1"

echo "--- on_open: opening the page files a request the scheduler honours ---"
page3="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/opened")"
has "$page3" "never refreshed" "the page serves what it has, which is nothing yet"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" schedule 2>&1)"
has "$out" "opened.orders: refreshed" "the open is honoured on the next pass"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" schedule 2>&1)"
hasnt "$out" "opened.orders" "and is not repeated: the request was a flag, and it is spent"
page4="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/opened")"
has "$page4" "orders: data as of" "the data arrived without anyone asking twice"

echo "--- a failing published dataset surfaces on its dashboard ---"
page5="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/down")"
has "$page5" "last refresh failed" "the failure is on the page, not only in a log"
has "$page5" "configured to fail" "with what the source said"

echo "--- crash residue is swept ---"
printf 'not a database' > "$ROOT/cache/timed/published/orders__staging.db"
"$GBASIC" src/gdash_cli.bas --root "$ROOT" schedule >/dev/null 2>&1
if [[ -f "$ROOT/cache/timed/published/orders__staging.db" ]]; then echo "  FAIL crash residue is swept"; fail=$((fail+1)); else echo "  ok   crash residue is swept"; pass=$((pass+1)); fi
audit="$(cat "$ROOT/log/audit.log")"
has "$audit" "sweep.staging" "and the sweep is audited"
has "$audit" "refresh.failed" "so is a failed refresh"
hasnt "$audit" "fixtures/orders" "and no profile internals reach the log"

echo "--- the scheduler process does the same on a period ---"
"$GBASIC" --line-buffered src/gdash_scheduler.bas --root "$ROOT" --every 1 > "$SCRATCH/sched.log" 2>&1 &
SCH=$!
curl -s -N --max-time 8 "http://127.0.0.1:$PORT/d/timed/events" > "$SCRATCH/sse2.txt" &
SSE2=$!
sleep 1
repoint fixtures/orders_moved.json
sleep 4
kill $SCH 2>/dev/null; wait $SCH 2>/dev/null
kill $SSE2 2>/dev/null; wait $SSE2 2>/dev/null
has "$(cat "$SCRATCH/sched.log")" "timed.orders: refreshed" "the scheduler picked up the changed data by itself"
has "$(cat "$SCRATCH/sse2.txt")" "data: refresh" "and every open tab was told over SSE, with no one pressing anything"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
rm -rf "$SCRATCH"
[[ -e "$SCRATCH" ]] && { echo "SCRATCH NOT CLEAN"; exit 1; }
echo "scratch clean: $SCRATCH removed"
echo "e2e: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
