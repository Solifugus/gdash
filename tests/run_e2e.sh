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

# Kill only processes actually NAMED gbasic. `pkill -f gdash_server.bas` also
# matches the shell that launched this script -- and killing that produces a
# mysterious exit code and no output at all, which cost an hour once.
reap(){
    local pid
    for pid in $(pgrep -f "gdash_server.bas\|gdash_scheduler.bas" 2>/dev/null); do
        [[ "$(cat /proc/$pid/comm 2>/dev/null)" == "gbasic" ]] || continue
        kill "$pid" 2>/dev/null
    done
}

# Without a trap, any early exit leaks a server holding the port, and the next
# suite to want it fails for a reason that has nothing to do with itself.
trap reap EXIT

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

echo "--- CLI: asking the data a question, and promoting the answer ---"
#
# The model is the seam, and here it is the PLATFORM'S OWN fixture transport:
# `llm.offline` reads <dir>/<format>_response.json, so a profile with
# provider "offline" exercises the entire path -- catalog, prompt, SQL check,
# unit notes, requalification, promotion -- with no key, no network and no
# token spent. It is the same thing an operator runs to check an install.
mkdir -p "$SCRATCH/model" "$SCRATCH/model_money"
cat > "$SCRATCH/model/anthropic_response.json" <<'JSON'
{"id":"msg_fixture","type":"message","role":"assistant","model":"fixture",
 "content":[{"type":"text","text":"select region, sum(amount) as total from orders.orders group by region"}],
 "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
JSON
# The second fixture is THE FAILURE THIS PHASE EXISTS FOR, as a model would
# actually produce it: the question is about dollars, the column holds cents,
# the SQL is valid and every name is grounded, and the number is wrong by a
# hundred. Nothing can refuse it -- someone may mean ten dollars -- so the
# whole of the defence is that the draft says what 1000 means.
cat > "$SCRATCH/model_money/anthropic_response.json" <<'JSON'
{"id":"msg_fixture","type":"message","role":"assistant","model":"fixture",
 "content":[{"type":"text","text":"select count(*) as n from orders.orders where amount > 1000"}],
 "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
JSON
cat > "$ROOT/etc/models.json" <<JSON
{ "default": "fixture",
  "fixture": { "provider": "offline", "model": "fixture-model", "offline_dir": "$SCRATCH/model" },
  "cents":   { "provider": "offline", "model": "fixture-model", "offline_dir": "$SCRATCH/model_money" } }
JSON

ask_out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" ask sales "total by region" 2>&1)"; ok "ask exits 0" "$?" "0"
has "$ask_out" "select region, sum(amount) as total" "the draft shows the query that was generated"
has "$ask_out" "data as of" "and when the data it read was refreshed"
has "$ask_out" "--promote" "and how to promote it, since that is the next thing anyone wants"

# Nothing is written until somebody promotes it.
hasnt "$(cat "$ROOT/lib/dashboards/sales/draft.json")" "total_by_region" "asking writes nothing into the record"

money_out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" --model cents ask sales "how many orders were over 1000 dollars?" 2>&1)"
ok "the cents question exits 0, because the query is valid" "$?" "0"
has "$money_out" "amount 1000 means" "the draft restates the literal in the column's own units"
has "$money_out" "\$10.00" "which is ten dollars, not a thousand"

promote_out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" ask sales "total by region" --promote total_by_region 2>&1)"; ok "promote exits 0" "$?" "0"
rec_after="$(cat "$ROOT/lib/dashboards/sales/draft.json")"
# REQUALIFIED: the NLQ catalog names the table orders.orders, a visual query
# names it orders, and a promoted visual that kept the first spelling would not
# resolve at all. The record is written by `encode`, which emits compact JSON.
has "$rec_after" '"sql":"select region, sum(amount) as total from orders group by region"' "the promoted query is requalified for the visual tier"
has "$rec_after" '"format":"currency"' "an aggregate over a money column is promoted as currency"
has "$rec_after" '"visual":"total_by_region"' "and it is placed on a tab, where it will be seen"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" validate sales 2>&1)"; ok "the record still validates" "$?" "0"

again="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" ask sales "total by region" --promote total_by_region 2>&1)"; ok "promoting over an existing visual exits 1" "$?" "1"
has "$again" "already has" "and says which name is taken"

# The ordinary configuration state, which must read as configuration rather
# than as a failure.
mv "$ROOT/etc/models.json" "$SCRATCH/models.json.away"
noask="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" ask sales "total by region" 2>&1)"; ok "no model configured exits 1" "$?" "1"
has "$noask" "models.json" "and names the file to write"
mv "$SCRATCH/models.json.away" "$ROOT/etc/models.json"

noq="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" ask sales 2>&1)"; ok "ask with no question exits 2" "$?" "2"
has "$noq" "usage" "with a usage line"

echo "--- the CLI says what it can do ---"
# Asked for help, gdash used to answer "which dashboard?" -- it treated
# --help as a verb, then demanded an argument for it. And the usage it did
# print named five verbs of eight, omitting every one a new operator needs in
# order to give themselves a login. Both were in the way of the first ten
# minutes somebody spends with gdash, which is the cheapest place to lose them.
help_out="$("$GBASIC" src/gdash_cli.bas --help 2>&1)"
has "$help_out" "user add" "help names the command that creates a login"
has "$help_out" "source check" "and the one that tests a connection before 3am"
has "$help_out" "auth   check" "and the one that tests the directory"
has "$help_out" "rollback" "and the way back from a bad publish"
hasnt "$help_out" "which dashboard" "asking for help is not answered with a question"

unknown="$("$GBASIC" src/gdash_cli.bas frobnicate 2>&1)"
has "$unknown" "unknown command: frobnicate" "an unknown command is named as one"
has "$unknown" "known commands:" "and the alternatives are listed"
hasnt "$unknown" "which dashboard" "not mistaken for a missing argument"

noname="$("$GBASIC" src/gdash_cli.bas validate 2>&1)"
has "$noname" "validate takes the name of one" "a real command missing its argument says which argument"

echo "--- server ---"
GDASH_ROOT="$ROOT" "$GBASIC" --line-buffered src/gdash_server.bas > "$SCRATCH/server.log" 2>&1 &
SRV=$!
for i in $(seq 1 60); do grep -q "listening" "$SCRATCH/server.log" 2>/dev/null && break; sleep 0.25; done
has "$(cat "$SCRATCH/server.log")" "listening" "server started"

page="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
has "$page" "<svg" "page carries the bar mark as SVG"
has "$page" 'class="gdash-value"' "page carries the value mark"
has "$page" '$4,927.05' "value mark shows the exact grand total"
has "$page" "data as of" "page shows data-as-of"
has "$page" 'data-param="region"' "page carries the slicer bound to :region"
has "$page" "<option" "slicer options came from a query over the dataset"
has "$page" "north" "slicer lists a value only the data knows"
# The shim's EventSource line is page furniture -- it is emitted whatever
# rendered, and its URL is built from location.pathname, so nothing about it
# is specific to this dashboard. Asserting on it proved nothing (finding
# G6-14). The real coverage is further down, where a refresh performed by
# another process arrives on an open stream as `data: refresh`.

echo "--- two datasets, joined with no schema prefix (design §3) ---"
has "$page" "Ada Okonjo" "a visual joins the second dataset and renders a value only it knows"
has "$page" "orders: data as of" "the status line names the first dataset"
has "$page" "regions: data as of" "and the second, because one line for a dashboard stops being true"

echo "--- tabs and the table mark (GDASH-1) ---"
has "$page" 'class="gdash-tabs"' "multi-tab record renders a tab bar"
has "$page" 'data-tab="2"' "all three tabs are present"
has "$page" 'data-pane="1" hidden' "non-active panes start hidden"
has "$page" "<table>" "the table mark rendered"
has "$page" 'data-tab="1"' "a second tab rendered, switchable client-side"
# every tab renders server-side in ONE response -- the Trend tab's line chart
# is in the page even though the Overview tab is showing.
has "$page" "trend_by_region" "a hidden tab's visual is already rendered"
has "$page" "justify-content:space-between" "space maps to flex justification"
has "$page" "flex:2 1 0" "a weighted child flexes"
has "$page" "gap:16px;justify-content" "gap is applied to the layout, not just defined in the stylesheet"

echo "--- publishing into an empty cache says so ---"
# Draft and published data never share a directory (design §7), so the moment
# a dashboard is published its visuals read "No data yet" for every viewer
# until the published copy is refreshed. The natural first-run sequence is
# validate, refresh, publish -- and it used to end, silently, with a
# dashboard that looked broken.
pub_empty="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" publish private 2>&1)"
has "$pub_empty" "published private as" "the publish itself succeeds"
has "$pub_empty" "no data yet" "and says the published copy is empty"
has "$pub_empty" "gdash refresh private" "naming the command that fills it"

"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh private >/dev/null 2>&1
pub_full="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" publish private 2>&1)"
hasnt "$pub_full" "no data yet" "and the note is gone once there is data"

echo "--- the index lists only what the viewer may open ---"
# The root page used to say "open /d/<dashboard>" without saying which, so a
# viewer could reach nothing without being told a URL. A list of names is a
# disclosure, though: `private` has no access clause, and an anonymous viewer
# is refused it with 404 rather than 403 for exactly that reason (design §8).
index="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/")"
has "$index" 'href="/d/sales"' "the index links the dashboard that opted into open access"
hasnt "$index" 'href="/d/private"' "and does not name one an anonymous viewer may not open"
has "$index" '<ul class="gdash-index">' "the index renders as a list"

echo "--- access fails closed (design §8) ---"
# An anonymous viewer gets 404, not 403: on an intranet the existence of a
# dashboard is itself information, and 403 would confirm it.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/private")"
ok "record without access:open is refused to an anonymous viewer" "$code" "404"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/nosuch")"
ok "and an unknown dashboard is indistinguishable from it" "$code" "404"

echo "--- slicer round trip: only binding visuals re-run (design §2) ---"
resp="$(curl -s --max-time 10 -X POST -H 'content-type: application/json' -d '{"region":"east"}' "http://127.0.0.1:$PORT/d/sales/params")"
has "$resp" '"by_month"' "the visual binding :region re-rendered"
hasnt "$resp" '"grand_total"' "the visual that does not bind it stayed put"
has "$resp" "<svg" "the re-rendered fragment is a chart"

west="$(curl -s --max-time 10 -X POST -H 'content-type: application/json' -d '{"region":"west"}' "http://127.0.0.1:$PORT/d/sales/params")"
if [[ "$west" != "$resp" ]]; then echo "  ok   a different param value renders differently"; pass=$((pass+1));
else echo "  FAIL a different param value renders differently"; fail=$((fail+1)); fi

echo "--- global events reach the page by polling, not by a held stream (design §5) ---"
# GDASH-11: the page used to hold an EventSource open, which held a worker for
# as long as the tab was open. The same two facts now travel as JSON the
# browser asks for. `jq` is not assumed; the fields are read with python3,
# which this suite already requires.
vfield(){ python3 -c "import json,sys; print(json.load(sys.stdin)[sys.argv[1]])" "$1"; }

before="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/sales/version")"
has "$before" '"v"' "the version endpoint answers with the dataset version"
has "$before" '"pub"' "and the publish pointer, which is the other global fact"

# Refetching identical data no longer bumps the version, so the notification
# has to be driven by data that actually moved.
repoint fixtures/orders_moved.json
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales orders >/dev/null 2>&1
after="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/sales/version")"
if [[ "$(vfield v <<<"$after")" != "$(vfield v <<<"$before")" ]]; then
    echo "  ok   a refresh performed by another process moves the version a page polls"; pass=$((pass+1))
else echo "  FAIL the version did not move across a refresh"; fail=$((fail+1)); fi
ok "and the publish pointer did not move with it" "$(vfield pub <<<"$after")" "$(vfield pub <<<"$before")"

# The page has to carry the baseline it was rendered at, or its first poll
# would compare against a version it learned a moment too late.
page2="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
has "$page2" "var gdashV=\"$(vfield v <<<"$after")\"" "the page embeds the version it was rendered at"
has "$page2" "location.pathname+'/version'" "and polls for changes to it"
hasnt "$page2" "EventSource" "no page opens a stream any more -- that is the worker it used to hold"

# --- and the page's own JavaScript, executed -----------------------------
#
# The shim is built by string concatenation in gBASIC and nothing ever ran the
# result. That mattered less when it only enhanced a rendered page; it matters
# now that it carries the refresh notification the server used to push.
if command -v node >/dev/null 2>&1; then
    printf '%s' "$page2" > "$SCRATCH/page.html"
    python3 -c "
import re,sys
page=open(sys.argv[1]).read()
m=re.findall(r'<script>(.*?)</script>', page, re.S)
open(sys.argv[2],'w').write(m[-1] if m else '')
" "$SCRATCH/page.html" "$SCRATCH/shim.js"
    shimout="$(node tests/shim_check.js "$(vfield v <<<"$after")" "$(vfield pub <<<"$after")" < "$SCRATCH/shim.js" 2>&1)"
    echo "$shimout"
    pass=$((pass + $(grep -c '^  ok   ' <<<"$shimout")))
    fail=$((fail + $(grep -c '^  FAIL ' <<<"$shimout")))
else
    # Named rather than silently skipped: a suite that quietly tests less on
    # some machines is a suite that reports a number nobody can compare.
    echo "  SKIP the shim is not executed here -- node is not installed" >&2
fi

# The route is gone, not merely unused. Not because a stream must pin a worker
# -- a handler that returns parks the connection and does not (G11-13) -- but
# because a parked stream is reachable only from the worker that accepted it,
# so a notice would reach a fraction of viewers unless gdash ran one worker.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/sales/events")"
ok "the stream route is gone" "$code" "404"

# The version endpoint is as closed as the page it belongs to.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/private/version")"
ok "a dashboard an anonymous viewer may not open does not leak its version" "$code" "404"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/nosuch/version")"
ok "nor does one that does not exist answer differently" "$code" "404"

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
python3 "$HERE/e2e_drafts.py" "$ROOT"
for d in timed opened down; do
    out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" publish "$d" 2>&1)"
    has "$out" "published $d as 0001.json" "publish $d"
done
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
# EXPIRED SESSIONS GO ON THE SAME PASS. gdash_session.sweep existed and was
# tested from GDASH-4 and was called by nothing for three phases; /run clearing
# on reboot bounds the mess without bounding it well, and a host that stays up
# accumulates one file per abandoned browser.
mkdir -p "$ROOT/run/sessions"
stale="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
fresh="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
now=$(date +%s)
printf '{"format":1,"id":"%s","user":"","created":%s,"seen":%s,"data":{}}' "$stale" "$((now - 200000))" "$((now - 200000))" > "$ROOT/run/sessions/$stale.json"
printf '{"format":1,"id":"%s","user":"","created":%s,"seen":%s,"data":{}}' "$fresh" "$now" "$now" > "$ROOT/run/sessions/$fresh.json"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" schedule 2>&1)"
if [[ -f "$ROOT/run/sessions/$stale.json" ]]; then echo "  FAIL an expired session is swept on the pass"; fail=$((fail+1)); else echo "  ok   an expired session is swept on the pass"; pass=$((pass+1)); fi
if [[ -f "$ROOT/run/sessions/$fresh.json" ]]; then echo "  ok   and a live one is left alone"; pass=$((pass+1)); else echo "  FAIL a live session was swept too"; fail=$((fail+1)); fi
has "$out" "sessions swept" "the pass reports what it swept"

audit="$(cat "$ROOT/log/audit.log")"
has "$audit" "sweep.staging" "and the sweep is audited"
has "$audit" "refresh.failed" "so is a failed refresh"
hasnt "$audit" "fixtures/orders" "and no profile internals reach the log"

echo "--- the scheduler process does the same on a period ---"
"$GBASIC" --line-buffered src/gdash_scheduler.bas --root "$ROOT" --every 1 > "$SCRATCH/sched.log" 2>&1 &
SCH=$!
sched_before="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed/version" | vfield v)"
repoint fixtures/orders_moved.json
sleep 4
kill $SCH 2>/dev/null; wait $SCH 2>/dev/null
has "$(cat "$SCRATCH/sched.log")" "timed.orders: refreshed" "the scheduler picked up the changed data by itself"
sched_after="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed/version" | vfield v)"
if [[ "$sched_after" != "$sched_before" ]]; then
    echo "  ok   and every open tab would see it on its next poll, with no one pressing anything"; pass=$((pass+1))
else echo "  FAIL the scheduler's refresh was not visible to a polling page"; fail=$((fail+1)); fi

# ---------------------------------------------------------------------------
# The §7 lifecycle over HTTP.
# ---------------------------------------------------------------------------
echo "--- a viewer is pinned to the snapshot they opened (design §7) ---"
jar="$SCRATCH/cookies.txt"
rm -f "$jar"
page="$(curl -s -c "$jar" --max-time 10 "http://127.0.0.1:$PORT/d/timed")"
has "$page" "Sales" "the published dashboard renders"
has "$(cat "$jar")" "gdash_pin" "opening it pins the snapshot in a session cookie"
has "$(cat "$jar")" "0001.json" "naming the snapshot that was served"

# Publish a second version while that viewer is holding the first.
python3 - "$ROOT" <<'PYEOF'
import json,sys
p=sys.argv[1]+'/lib/dashboards/timed/draft.json'
d=json.load(open(p)); d['title']='Sales, second edition'
json.dump(d,open(p,'w'),indent=2)
PYEOF
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" publish timed 2>&1)"
has "$out" "0002.json" "a second version is published"

pinned="$(curl -s -b "$jar" --max-time 10 "http://127.0.0.1:$PORT/d/timed")"
hasnt "$pinned" "second edition" "the pinned viewer still sees the version they opened"
fresh="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed")"
has "$fresh" "second edition" "a viewer arriving now gets the new one"

# A pin naming a snapshot that is gone falls back rather than failing.
gone="$(curl -s -b "gdash_pin=8888.json" --max-time 10 "http://127.0.0.1:$PORT/d/timed")"
has "$gone" "second edition" "a pin whose snapshot is gone falls back to current"

echo "--- publish nudges; it does not yank the page away ---"
# The distinction the page acts on: `pub` moving reveals a notice, `v` moving
# reloads. A publish must move exactly one of them, or a pinned viewer is
# yanked onto a version they did not ask for (design §7).
pub_before="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed/version")"
"$GBASIC" src/gdash_cli.bas --root "$ROOT" publish timed >/dev/null 2>&1
pub_after="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed/version")"
if [[ "$(vfield pub <<<"$pub_after")" != "$(vfield pub <<<"$pub_before")" ]]; then
    echo "  ok   a publish moves the pointer a page polls"; pass=$((pass+1))
else echo "  FAIL a publish did not move the pointer"; fail=$((fail+1)); fi
ok "and is NOT announced as a data refresh" "$(vfield v <<<"$pub_after")" "$(vfield v <<<"$pub_before")"
has "$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed")" "gdashNotice()" "and the page shows a notice rather than reloading"
has "$fresh" 'id="gdash-notice"' "the page carries the banner the notice reveals"
has "$fresh" 'class="gdash-notice" hidden>' "hidden until there is something to say"

echo "--- rollback, and data that no longer answers the record's question ---"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" snapshots timed 2>&1)"
has "$out" "0001.json" "snapshots lists every version"
has "$out" "* 0003.json" "marking the one in force"

# Publish a version whose dataset asks a DIFFERENT question. The data on disk
# was fetched for the old query, so it now answers a question nobody is asking.
python3 - "$ROOT" <<'PYEOF'
import json,sys
p=sys.argv[1]+'/lib/dashboards/timed/draft.json'
d=json.load(open(p))
d['datasets']['orders']['sql']="select region, month, amount from sales.orders where region <> 'nowhere'"
d['datasets']['orders']['refresh']='manual'
del d['datasets']['orders']['every']
json.dump(d,open(p,'w'),indent=2)
PYEOF
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" publish timed 2>&1)"
has "$out" "published timed as 0004.json" "a version with a different query is published"

changed_page="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed")"
has "$changed_page" "definition changed" "the page says the data predates the record now serving it"
has "$changed_page" "<svg" "while every visual keeps rendering the data there is"

# The dataset is `manual`, so the scheduler must NOT go behind the author's
# back however stale the definition is.
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" schedule 2>&1)"
hasnt "$out" "timed.orders" "a manual dataset is not refreshed by the scheduler, stale definition or not"
still="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed")"
has "$still" "definition changed" "so it still says so"

# A person asking refreshes what the dashboard SERVES -- the published data,
# not the draft, which is the only way a published manual dataset ever moves.
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh timed 2>&1)"
# The new query returns the same rows, so the CONTENT is unchanged even though
# the definition is not: no swap, no version bump, no reload for anyone -- and
# the definition is recorded anyway, which is what clears the warning.
has "$out" "unchanged timed.orders" "a person can refresh a published manual dataset"
settled="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed")"
hasnt "$settled" "definition changed" "and the record and its data agree again"

# Rolling back puts the OLDER query back in force, and the data on disk was
# fetched for the newer one. The same rule catches it from the other side.
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" rollback timed 0003.json 2>&1)"
has "$out" "rolled timed back to 0003.json" "rollback moves current"
after_roll="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed")"
has "$after_roll" "definition changed" "and a rollback is caught by the same rule, from the other side"
has "$after_roll" "<svg" "with the dashboard still rendering throughout"

echo "--- the diff endpoint (design §7) ---"
d1="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed/diff?from=0001.json&to=0002.json")"
has "$d1" '"changed":true' "two different snapshots differ"
has "$d1" "second edition" "and the diff names what changed"
d2="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/timed/diff?from=0002.json&to=0002.json")"
has "$d2" '"changed":false' "a snapshot does not differ from itself"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/timed/diff?from=9999.json")"
ok "a snapshot that does not exist is 404" "$code" "404"
# A snapshot is a version of a dashboard, so whoever may not see the dashboard
# may not see its history -- and is told the same nothing about both.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/private/diff")"
ok "history follows the dashboard's own access rule" "$code" "404"

echo "--- an invalid draft cannot be published ---"
printf '{ "format": 1 }' > "$ROOT/lib/dashboards/timed/draft.json"
before_ptr="$(cat "$ROOT/lib/dashboards/timed/current")"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" publish timed 2>&1)"
ok "publishing an invalid draft exits nonzero" "$?" "1"
has "$out" "nothing was published" "and says nothing was published"
ok "current did not move" "$(cat "$ROOT/lib/dashboards/timed/current")" "$before_ptr"


# ---------------------------------------------------------------------------
# Identity (GDASH-4).
# ---------------------------------------------------------------------------
echo "--- accounts, and no default anything ---"
printf 'fake-analyst-pw\nfake-analyst-pw\n' | "$GBASIC" src/gdash_cli.bas --root "$ROOT" user add ada --email ada@example.invalid --groups analysts >/dev/null 2>&1
ok "creating the first account exits 0" "$?" "0"
printf 'fake-outsider-pw\nfake-outsider-pw\n' | "$GBASIC" src/gdash_cli.bas --root "$ROOT" user add bo --email bo@example.invalid --groups shipping >/dev/null 2>&1
printf 'fake-boss-pw\nfake-boss-pw\n' | "$GBASIC" src/gdash_cli.bas --root "$ROOT" user add root_of_all --admin >/dev/null 2>&1
ok "the user file is 0600" "$(stat -c '%a' "$ROOT/etc/users.json")" "600"
hasnt "$(cat "$ROOT/etc/users.json")" "fake-analyst-pw" "no password is stored, only its hash"

# A dashboard shared with one group, and nothing else.
python3 - "$ROOT" <<'PYEOF'
import json,os,sys
r=sys.argv[1]
d=json.load(open('dashboards/sales/draft.json'))
d['name']='team'; d.pop('access',None)
d['view_groups']=['analysts']
d['edit_groups']=['analysts']
os.makedirs(f'{r}/lib/dashboards/team', exist_ok=True)
json.dump(d, open(f'{r}/lib/dashboards/team/draft.json','w'), indent=2)
PYEOF
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh team >/dev/null 2>&1

echo "--- login (design §8) ---"
jarA="$SCRATCH/ada.txt"; rm -f "$jarA"
form="$(curl -s -c "$jarA" --max-time 10 "http://127.0.0.1:$PORT/login")"
has "$form" 'name="csrf"' "the login form carries a CSRF token"
has "$(cat "$jarA")" "gdash_session" "and a session to bind it to"
tokA="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' <<<"$form")"
preA="$(awk '/gdash_session/{print $7}' "$jarA")"

# Wrong password, right username: refused, and refused the same way as a
# username that does not exist.
bad1="$(curl -s -b "$jarA" -c "$jarA" --max-time 10 -X POST -d "csrf=$tokA&user=ada&pass=wrong" "http://127.0.0.1:$PORT/login")"
bad2="$(curl -s -b "$jarA" -c "$jarA" --max-time 10 -X POST -d "csrf=$tokA&user=nobody&pass=wrong" "http://127.0.0.1:$PORT/login")"
has "$bad1" "do not match" "a wrong password is refused"
if [[ "$(grep -o 'do not match' <<<"$bad1")" == "$(grep -o 'do not match' <<<"$bad2")" ]]; then
    echo "  ok   an unknown user is refused in exactly the same words"; pass=$((pass+1))
else echo "  FAIL an unknown user is refused in exactly the same words"; fail=$((fail+1)); fi

# A post with no CSRF token at all.
nocsrf="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" --max-time 10 -X POST -d "user=ada&pass=fake-analyst-pw" "http://127.0.0.1:$PORT/login")"
ok "a login without a CSRF token is refused" "$nocsrf" "400"

# The real thing.
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" -c "$jarA" --max-time 10 -X POST -d "csrf=$tokA&user=ada&pass=fake-analyst-pw&next=/d/team" "http://127.0.0.1:$PORT/login")"
ok "a correct login redirects" "$code" "303"
postA="$(awk '/gdash_session/{print $7}' "$jarA")"
if [[ -n "$preA" && -n "$postA" && "$preA" != "$postA" ]]; then
    echo "  ok   the session id changed at the privilege change (fixation defence)"; pass=$((pass+1))
else echo "  FAIL the session id changed at the privilege change (got '$preA' -> '$postA')"; fail=$((fail+1)); fi

page_who="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
has "$page_who" "sign out" "a signed-in viewer is offered the way out"
has "$page_who" 'name="csrf"' "and the logout form carries its own token"
anon_who="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
has "$anon_who" "Sign in" "an anonymous viewer on an open dashboard is offered the way in"

who="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/whoami")"
has "$who" '"authenticated":true' "the browser is now authenticated"
has "$who" '"user":"ada"' "as the user who signed in"

echo "--- TLS ---"
# gdash refuses to start under a TLS configuration this platform cannot honour
# (finding G8-6): web.configure accepts cert/key and serve ignores them, so
# starting would listen in cleartext while looking encrypted.
#
# WHEN THIS ASSERTION FAILS, THE PLATFORM HAS PROBABLY BEEN FIXED. Re-measure
# with tests in gdash8_platform_report_tls.md and remove the refusal.
tls_out="$(GDASH_ROOT="$ROOT" GDASH_TLS_CERT=/nonexistent/cert.pem GDASH_TLS_KEY=/nonexistent/key.pem \
    "$GBASIC" src/gdash_server.bas 2>&1)"
has "$tls_out" "cannot honour it" "a TLS configuration is refused rather than served in the clear"
half="$(GDASH_ROOT="$ROOT" GDASH_TLS_CERT=/nonexistent/cert.pem "$GBASIC" src/gdash_server.bas 2>&1)"
has "$half" "refusing to start in cleartext" "and half a pair is refused for its own reason"

echo "--- a guesser is slowed, a typist is not ---"
# Three failures are free, because a person who mistypes twice and gets it
# right should wait exactly as long as somebody who typed it right first time.
# The fourth costs a second, and it costs it whether or not the account exists.
jarT="$SCRATCH/throttle.txt"; rm -f "$jarT"
formT="$(curl -s -c "$jarT" --max-time 10 "http://127.0.0.1:$PORT/login")"
tokT="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' <<<"$formT")"
#
# FOUR attempts, not five, AND ALL FOUR IN ONE CURL. The fifth was asserted as
# a second 429 and failed perhaps one run in three; four attempts then failed
# the OTHER way on a loaded machine, with the fourth coming back 401. Both have
# the same cause and it is not a defect: the wait after the third failure is
# ONE SECOND, so an attempt that arrives more than a second later has genuinely
# waited and is genuinely entitled to try. Two curl processes and a /whoami
# round trip per attempt can spend that second on their own.
#
# So: one curl process, one connection, four POSTs, no round trip between them.
# A failed login does not regenerate the session, so the same CSRF token is
# good for all four -- which is what makes dropping the /whoami legitimate
# rather than merely convenient.
#
# The schedule itself is pinned exactly in test_throttle.bas against an
# injected clock, where it costs no wall time and cannot race. What the
# end-to-end run is for is that the throttle is WIRED IN -- that a 429 reaches
# the socket at all.
attempt(){ printf -- '-s -o /dev/null -w %%{http_code}_ -b %s -X POST -d csrf=%s&user=ada&pass=wrong-%s http://127.0.0.1:%s/login\n' "$jarT" "$tokT" "$1" "$PORT"; }
codes="$(curl $(attempt 1) --next $(attempt 2) --next $(attempt 3) --next $(attempt 4))"
ok "three failures are free, then the guesser waits" "$codes" "401_401_401_429_"

# And the wait ENDS. A lockout that never lifts is a denial of service an
# attacker can aim at someone else's account by failing on their behalf, so
# the other half of the property matters as much as the first. Two seconds is
# comfortably past the one second owed, and waiting longer is never wrong.
sleep 2
ok "and having waited, they are let through to fail again" "$(curl $(attempt 5))" "401_"
has "$(cat "$ROOT/log/audit.log")" '"event":"login.throttled"' "and the throttling is audited"

# Per USERNAME, not per address: an intranet behind one NAT is one address, and
# throttling an address throttles a floor. Same client, same cookie jar, a
# different name -- unaffected.
other="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarT" -c "$jarT" --max-time 10 \
    -X POST -d "csrf=$tokT&user=bo&pass=fake-outsider-pw" "http://127.0.0.1:$PORT/login")"
ok "another user from the same client is not throttled" "$other" "303"

echo "--- per-dashboard groups ---"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/team")"
ok "an anonymous viewer cannot see a group dashboard, and cannot tell it exists" "$code" "404"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
ok "a member of its group can" "$code" "200"

# Someone authenticated but in the wrong group gets 403: for them the
# dashboard's existence is not the secret, their access to it is.
jarB="$SCRATCH/bo.txt"; rm -f "$jarB"
formB="$(curl -s -c "$jarB" --max-time 10 "http://127.0.0.1:$PORT/login")"
tokB="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' <<<"$formB")"
curl -s -o /dev/null -b "$jarB" -c "$jarB" --max-time 10 -X POST -d "csrf=$tokB&user=bo&pass=fake-outsider-pw" "http://127.0.0.1:$PORT/login"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarB" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
ok "an authenticated non-member gets 403, not 404" "$code" "403"
has "$(cat "$ROOT/log/audit.log")" "access.denied" "and the denial is audited"

# An admin sees everything, without being in any group.
jarC="$SCRATCH/boss.txt"; rm -f "$jarC"
formC="$(curl -s -c "$jarC" --max-time 10 "http://127.0.0.1:$PORT/login")"
tokC="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' <<<"$formC")"
curl -s -o /dev/null -b "$jarC" -c "$jarC" --max-time 10 -X POST -d "csrf=$tokC&user=root_of_all&pass=fake-boss-pw" "http://127.0.0.1:$PORT/login"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarC" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
ok "an admin needs no group" "$code" "200"

echo "--- money that is not dollars, over HTTP ---"
#
# Every money figure gdash rendered for thirteen phases was US dollars at scale
# 2, because every fixture was. `treasury` is a banking-shaped dashboard --
# USD at scale 2 and JPY at scale 0 in ONE dataset, as a multi-currency
# position report is, plus rates at scale 4 -- and it is here so that "money
# that is not dollars" is something the suite renders on every run rather than
# something nobody tried.
mkdir -p "$ROOT/lib/dashboards/treasury"
cp dashboards/treasury/draft.json "$ROOT/lib/dashboards/treasury/draft.json"
python3 - "$ROOT" <<'PYEOF'
import json,sys
r=sys.argv[1]
c=json.load(open(r+'/etc/connections.json'))
c['core_banking']        = {"kind":"fixture","path":"fixtures/bank_positions.json"}
c['core_banking_ledger'] = {"kind":"fixture","path":"fixtures/bank_ledger.json"}
c['rates']               = {"kind":"fixture","path":"fixtures/bank_fx.json"}
json.dump(c, open(r+'/etc/connections.json','w'), indent=2)
PYEOF
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh treasury >/dev/null 2>&1
ok "the treasury dashboard refreshes" "$?" "0"

# Fetched as the admin: `treasury` does not opt into open access, and a
# banking dashboard is exactly the kind that should not.
tre="$(curl -s -b "$jarC" --max-time 10 "http://127.0.0.1:$PORT/d/treasury")"
# THE DEFECT, AS A PAGE. Every yen figure used to render at the dollar scale:
# a hundred times small, in a table that looked entirely normal.
has "$tre" '$1,250,750.25' "the dollar column renders at its own scale"
has "$tre" '-$90,425.10' "including a negative balance"
has "$tre" "¥430,000" "and the yen column renders at ITS scale"
has "$tre" "¥12" "a balance of twelve yen is twelve yen"
hasnt "$tre" "¥4,300" "and not four thousand three hundred, which is what one shared scale made of it"
# The yen sign is ONE codepoint. It shipped as the two UTF-8 bytes of one,
# handed to chr(), so every non-dollar figure read Â¥ / Â£ / â‚¬.
hasnt "$tre" "Â¥" "the yen sign is not double-encoded"
# A visual over `ledger` alone used to refuse outright, because `positions`
# was attached and its scales disagreed.
has "$tre" "<svg" "a chart over a single-currency dataset still draws"
hasnt "$tre" "disagree on scale" "and is not disabled by a sibling it never touches"

echo "--- CSRF on a state-changing route ---"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" --max-time 10 -X POST "http://127.0.0.1:$PORT/d/team/refresh")"
ok "a refresh without a CSRF token is refused" "$code" "400"
tokA2="$(sed -n 's/.*"csrf":"\([^"]*\)".*/\1/p' <<<"$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/whoami")")"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" -H "x-gdash-csrf: $tokA2" --max-time 10 -X POST "http://127.0.0.1:$PORT/d/team/refresh")"
ok "and accepted with one" "$code" "200"
# ada's own session, but somebody else's token. (bo would be refused at
# authorization first, which is the right order and a different test.)
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" -H "x-gdash-csrf: $tokC" --max-time 10 -X POST "http://127.0.0.1:$PORT/d/team/refresh")"
ok "another session's token does not work" "$code" "400"

echo "--- user_* reaches the query, and only from the server (design §5) ---"
python3 - "$ROOT" <<'PYEOF'
import json,sys
r=sys.argv[1]
p=f'{r}/lib/dashboards/team/draft.json'
d=json.load(open(p))
# A `value` mark, because its title is HTML gdash emits and is therefore
# something the run can look for; a bar's title lives inside the chart
# library's SVG. The point of the test is the WHERE clause either way.
d['visuals']['mine']={
 'dataset':'orders',
 'sql':"select sum(amount) as total from orders where :user_email like '%ada%'",
 'encoding':{'mark':'value','value':'total','format':'currency','currency':'USD','title':'Only for ada'}}
d['tabs'][0]['layout']['vert'].append({'visual':'mine'})
json.dump(d, open(p,'w'), indent=2)
PYEOF
# The visual's title only appears when the query returned rows, so its
# presence IS the assertion that :user_email carried the right identity.
mine="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
has "$mine" "Only for ada" "a visual binding :user_email renders for the matching identity"
has "$mine" 'gdash-value-number">$' "with a figure, which an empty result would not render"

# The admin has no email, so the same query returns nothing for them. Same
# dashboard, same dataset, different rows -- design §5's whole claim.
boss="$(curl -s -b "$jarC" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
hasnt "$boss" "Only for ada" "and renders nothing for an identity it does not match"

# ...and asking to be someone else changes nothing, because user_* is
# injected from the session and never merged from the client.
spoof="$(curl -s -b "$jarC" --max-time 10 "http://127.0.0.1:$PORT/d/team?user_email=ada@example.invalid")"
hasnt "$spoof" "Only for ada" "a client-supplied user_email is ignored, not honoured"

echo "--- the marks GDASH-7 added, over HTTP, with a theme ---"
#
# The new marks have unit coverage; this is the only place they are rendered by
# a server, through the record, from a real staged database. The line-family
# marks need a NUMERIC x (G7-3), which the SQL supplies -- the fixture's month
# is text, which is exactly the case that used to draw nothing.
python3 - "$ROOT" <<'MKCHARTS'
import json, os, sys
r = sys.argv[1]
base = json.load(open('dashboards/sales/draft.json'))
d = {"format": 1, "name": "charts", "title": "Every mark", "access": "open",
     "datasets": {"orders": base["datasets"]["orders"]},
     "params": {}, "controls": {}, "visuals": {}, "tabs": []}
period = "cast(substr(month, 6, 2) as integer)"
d["visuals"]["trend"] = {
    "dataset": "orders",
    "sql": f"select {period} as period, sum(amount) as total from orders group by period order by period",
    "encoding": {"mark": "line", "x": "period", "y": "total",
                 "title": "Trend", "x_label": "Month", "y_label": "Revenue"}}
d["visuals"]["band"] = {
    "dataset": "orders",
    "sql": f"select {period} as period, region as region, sum(amount) as total "
           f"from orders group by period, region order by period, region",
    "encoding": {"mark": "area", "x": "period", "y": "total", "series": "region", "stacked": True}}
d["visuals"]["points"] = {
    "dataset": "orders",
    "sql": f"select {period} as period, sum(amount) as total from orders group by period order by period",
    "encoding": {"mark": "scatter", "x": "period", "y": "total", "grid": False}}
d["visuals"]["share"] = {
    "dataset": "orders",
    "sql": "select region as region, sum(amount) as total from orders group by region order by region",
    "encoding": {"mark": "pie", "label": "region", "value": "total", "title": "Share",
                 "colors": {"west": "#ff00ff"}}}
d["tabs"] = [{"name": "All", "layout": {"vert": [
    {"visual": "trend"}, {"visual": "band"}, {"visual": "points"}, {"visual": "share"}]}}]
os.makedirs(f'{r}/lib/dashboards/charts', exist_ok=True)
json.dump(d, open(f'{r}/lib/dashboards/charts/draft.json', 'w'), indent=2)
MKCHARTS
cat > "$ROOT/etc/theme.json" <<'THEME'
{ "format": 1, "palette": ["#123456", "#654321"], "font_size": 15 }
THEME

out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" validate charts 2>&1)"
has "$out" "validates" "a dashboard using every new mark validates"
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh charts >/dev/null 2>&1
charts="$(curl -s --max-time 20 "http://127.0.0.1:$PORT/d/charts")"
# `gdash-error` alone is a STYLESHEET RULE, present on every page -- the exact
# hollow-assertion shape tests/assertion_audit.py exists to refuse. The needle
# is the markup an error box actually emits.
hasnt "$charts" 'class="gdash-error"' "and renders without an error box"
has "$charts" "<path" "the line and area marks draw paths"
has "$charts" "<circle" "the scatter draws points"
has "$charts" ">Trend<" "a chart title reaches the SVG"
has "$charts" ">Month<" "so does an axis label"
has "$charts" "#123456" "the server theme's palette is used"
has "$charts" "#ff00ff" "and a record's per-series colour overrides it"

echo "--- click to publish a param ---"
#
# The click is browser JavaScript and this runner has no browser. What it CAN
# assert is every piece the click depends on: the markup contract that tells it
# which param and which value, the listener that reads them, and the endpoint
# it posts to answering the value a click would send. If all three hold, the
# only untested step is the browser dispatching a click event.
python3 - "$ROOT" <<'MKCLICK'
import json, sys
r = sys.argv[1]
p = f'{r}/lib/dashboards/team/draft.json'
d = json.load(open(p))
d['params'] = dict(d.get('params') or {}, region={'default': 'west'})
d['visuals']['by_region'] = {
    'dataset': 'orders',
    'sql': 'select region as region, sum(amount) as total from orders group by region order by region',
    'encoding': {'mark': 'bar', 'x': 'region', 'y': 'total', 'publishes': 'region',
                 'format': 'currency', 'currency': 'USD'}}
d['visuals']['picked'] = {
    'dataset': 'orders',
    'sql': "select sum(amount) as total from orders where region = :region",
    'encoding': {'mark': 'value', 'value': 'total', 'format': 'currency',
                 'currency': 'USD', 'title': 'Picked region'}}
d['tabs'][0]['layout']['vert'].append({'visual': 'by_region'})
d['tabs'][0]['layout']['vert'].append({'visual': 'picked'})
json.dump(d, open(p, 'w'), indent=2)
MKCLICK
"$GBASIC" src/gdash_cli.bas --root "$ROOT" validate team >/dev/null 2>&1
page="$(curl -s -b "$jarA" --max-time 20 "http://127.0.0.1:$PORT/d/team")"
has "$page" 'data-publishes="region"' "a publishing chart names its param in the page"
has "$page" "data-key=" "and its bars carry the values a click would send"
# The shim's own content is asserted in tests/test_app.bas, where it is
# PRODUCED. Asserting it by fetching a dashboard tests page furniture -- it is
# on every page whatever the dashboard does -- which is what the assertion
# audit refuses, correctly, even when the furniture is the thing you meant.

# What the click does, done directly: the endpoint answers with re-rendered
# fragments for exactly the visuals that bind the param.
clicked="$(curl -s -b "$jarA" --max-time 20 -X POST -H 'content-type: application/json' \
    -d '{"region":"east"}' "http://127.0.0.1:$PORT/d/team/params")"
has "$clicked" '"picked"' "posting the clicked value re-renders the visual that binds it"
hasnt "$clicked" '"by_region"' "and not the chart that published it, which does not bind it"

# A chart that did not opt in carries nothing for a click to find.
# The needle is the ATTRIBUTE WITH A VALUE, not the bare name: the shim's own
# `closest('[data-publishes]')` puts the bare name on every page, so the first
# version of this passed for the wrong reason -- which is what
# tests/assertion_audit.py exists to refuse.
hasnt "$(curl -s -b "$jarA" --max-time 20 "http://127.0.0.1:$PORT/d/sales")" 'data-publishes="' "a dashboard that did not ask for this has no click surface"

echo "--- preview-as (design §8) ---"
# `team` is a draft and ada is in its edit_groups, so she is an editor of it.
tokA3="$(sed -n 's/.*"csrf":"\([^"]*\)".*/\1/p' <<<"$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/whoami")")"
page="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
has "$page" 'action="/d/team/preview"' "an editor sees the preview-as control on a draft"

# ...and nobody sees it on a published dashboard, editor or not. `timed` is
# published and the admin may edit anything.
pub="$(curl -s -b "$jarC" --max-time 10 "http://127.0.0.1:$PORT/d/timed")"
# The class name is in the stylesheet on every page, so the assertion is the
# form's action -- the thing that exists only when the control is rendered.
hasnt "$pub" 'action="/d/timed/preview"' "and nobody sees it on a published dashboard"

# A non-editor cannot preview-as at all. bo is in shipping, not analysts, so
# team does not exist as far as bo is concerned.
jarB="$SCRATCH/bo.txt"; rm -f "$jarB"
formB="$(curl -s -c "$jarB" --max-time 10 "http://127.0.0.1:$PORT/login")"
tokB="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' <<<"$formB")"
curl -s -o /dev/null -b "$jarB" -c "$jarB" --max-time 10 -X POST -d "csrf=$tokB&user=bo&pass=fake-outsider-pw" "http://127.0.0.1:$PORT/login"
tokB2="$(sed -n 's/.*"csrf":"\([^"]*\)".*/\1/p' <<<"$(curl -s -b "$jarB" --max-time 10 "http://127.0.0.1:$PORT/whoami")")"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarB" --max-time 10 -X POST -d "csrf=$tokB2&as_name=x&as_groups=analysts" "http://127.0.0.1:$PORT/d/team/preview")"
ok "a non-editor cannot preview-as" "$code" "403"

# Assume an identity. The `mine` visual binds :user_email and only renders for
# ada, so previewing as somebody else must make it disappear -- which is the
# assertion that preview-as reached the QUERY and not just the banner.
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" --max-time 10 -X POST -d "csrf=$tokA3&as_name=Test+Person&as_email=test@example.invalid&as_groups=shipping,+finance" "http://127.0.0.1:$PORT/d/team/preview")"
ok "an editor may assume an identity" "$code" "303"
seen="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
has "$seen" "Previewing as Test Person" "and the page says so, unmissably"
has "$seen" "shipping, finance" "naming the groups being assumed"
hasnt "$seen" "Only for ada" "the queries see the assumed identity, not the real one"

# ...but authorization does not move an inch. `private` opts into no access
# and names no groups, so it is admins-only; ada previewing as anything at all
# is still ada as far as the door is concerned.
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/private")"
ok "preview-as is not a way into a dashboard you may not open" "$code" "403"
whoami_pv="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/whoami")"
has "$whoami_pv" '"user":"ada"' "and the viewer is still themselves"

# It is scoped to the dashboard it was set on.
other="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
hasnt "$other" "Previewing as" "a preview on one draft does not leak into another dashboard"

# Every use is audited, and the audit names who was pretending.
has "$(cat "$ROOT/log/audit.log")" '"event":"preview.as"' "preview-as is audited"
has "$(cat "$ROOT/log/audit.log")" '"user":"ada"' "naming the real identity"
has "$(cat "$ROOT/log/audit.log")" '"as_name":"Test Person"' "and the assumed one"

# And it ends.
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" --max-time 10 -X POST -d "csrf=$tokA3&clear=1" "http://127.0.0.1:$PORT/d/team/preview")"
ok "previewing stops" "$code" "303"
back="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
has "$back" "Only for ada" "and the real identity comes back"
hasnt "$back" "Previewing as" "with the banner gone"

echo "--- asking in a browser, and promoting what it draws ---"
#
# The CLI path is asserted earlier. What this adds is the half only a browser
# has: the suggested visual is RENDERED -- ordinary query, ordinary attach set,
# ordinary renderer -- so a preview that draws is a promise that the promoted
# visual draws. And it is fail-closed: promotion edits the draft record, so the
# draft's own edit groups decide, and bo is not in them.
tokA4="$(sed -n 's/.*"csrf":"\([^"]*\)".*/\1/p' <<<"$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/whoami")")"

teampage="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
has "$teampage" 'href="/d/team/ask"' "an editor is offered a way in from the dashboard"

askform="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/team/ask")"
has "$askform" 'action="/d/team/ask"' "the ask page offers a form"
has "$askform" 'name="csrf"' "carrying a CSRF token, because asking spends money"

# A stranger to this dashboard gets nothing, and gets it exactly the way
# /d/team already answers: 404 for an anonymous request, because the existence
# of the dashboard is itself the secret; 403 for bo, who is authenticated and
# for whom the secret is his access rather than its existence. Asserted here
# rather than assumed, because a new route is a new place to leak.
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarB" --max-time 10 "http://127.0.0.1:$PORT/d/team/ask")"
ok "a non-member cannot reach the ask page" "$code" "403"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarB" --max-time 10 -X POST -d "csrf=$tokA4&question=anything" "http://127.0.0.1:$PORT/d/team/ask")"
ok "nor post to it" "$code" "403"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/team/ask")"
ok "and an anonymous request is not even told the dashboard is there" "$code" "404"

# VIEWING IS NOT EDITING. `sales` is access: open, so bo may read it; asking a
# question edits the draft, and he may not do that. This is the case the
# dashboard's own access check cannot make, because it passes.
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarB" --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
ok "bo may view an open dashboard" "$code" "200"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarB" --max-time 10 "http://127.0.0.1:$PORT/d/sales/ask")"
ok "and may not ask it anything, because asking edits the draft" "$code" "403"
openpage="$(curl -s -b "$jarB" --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
hasnt "$openpage" 'href="/d/sales/ask"' "and is not offered a link to somewhere he cannot go"

# Asking without a token is refused before a single token is spent.
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" --max-time 10 -X POST -d "question=total by region" "http://127.0.0.1:$PORT/d/team/ask")"
ok "asking without a CSRF token is refused" "$code" "400"

asked="$(curl -s -b "$jarA" --max-time 10 -X POST -d "csrf=$tokA4" --data-urlencode "question=total by region" "http://127.0.0.1:$PORT/d/team/ask")"
has "$asked" "select region, sum(amount) as total from orders.orders group by region" "the draft shows the query the model wrote"
has "$asked" "data as of" "and when the data it read was refreshed"
# THE RENDER IS THE POINT of doing this in a browser rather than a terminal.
has "$asked" "<svg" "and draws the visual it would promote"
# In dollars. An aggregate of minor units is still minor units, and a chart
# whose axis reads 325100 for \$3,251.00 is the step-0 failure in a picture.
has "$asked" "\$3,000.00" "with a money axis in dollars, not in cents"
has "$asked" 'action="/d/team/ask/promote"' "and offers to promote it"

# Nothing is written by asking.
hasnt "$(cat "$ROOT/lib/dashboards/team/draft.json")" "by_question" "asking writes nothing into the record"

code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" --max-time 10 -X POST -d "csrf=$tokA4&visual=by_question" "http://127.0.0.1:$PORT/d/team/ask/promote")"
ok "promoting redirects to the dashboard" "$code" "303"
teamrec="$(cat "$ROOT/lib/dashboards/team/draft.json")"
has "$teamrec" '"sql":"select region, sum(amount) as total from orders group by region"' "the promoted query is requalified for the visual tier"
has "$teamrec" '"format":"currency"' "and promoted as currency, because it aggregates a money column"
has "$teamrec" '"visual":"by_question"' "and placed on a tab, where it will be seen"

after="$(curl -s -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
has "$after" "by_question" "the dashboard now renders it"

# The draft rides the session, so a promote with nothing held says so rather
# than spending another model call or accepting SQL from the browser.
jarD="$SCRATCH/ada2.txt"; rm -f "$jarD"
formD="$(curl -s -c "$jarD" --max-time 10 "http://127.0.0.1:$PORT/login")"
tokD="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' <<<"$formD")"
curl -s -o /dev/null -b "$jarD" -c "$jarD" --max-time 10 -X POST -d "csrf=$tokD&user=ada&pass=fake-analyst-pw" "http://127.0.0.1:$PORT/login"
tokD2="$(sed -n 's/.*"csrf":"\([^"]*\)".*/\1/p' <<<"$(curl -s -b "$jarD" --max-time 10 "http://127.0.0.1:$PORT/whoami")")"
nodraft="$(curl -s -b "$jarD" --max-time 10 -X POST -d "csrf=$tokD2&visual=whatever" "http://127.0.0.1:$PORT/d/team/ask/promote")"
has "$nodraft" "no longer in this session" "a promote with no draft held says so"
hasnt "$(cat "$ROOT/lib/dashboards/team/draft.json")" "whatever" "and writes nothing"

echo "--- logout ---"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" -H "x-gdash-csrf: $tokA2" -c "$jarA" --max-time 10 -X POST "http://127.0.0.1:$PORT/logout")"
ok "logout redirects" "$code" "303"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jarA" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
ok "and the dashboard is no longer reachable with that cookie" "$code" "404"
has "$(cat "$ROOT/log/audit.log")" '"login"' "logins are audited"
has "$(cat "$ROOT/log/audit.log")" '"logout"' "so are logouts"
has "$(cat "$ROOT/log/audit.log")" "login.failed" "so are failures"
hasnt "$(cat "$ROOT/log/audit.log")" "fake-analyst-pw" "and no password reaches the log"

# An open dashboard is still open to anyone: per-dashboard opt-in, unchanged.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
ok "access: open still serves anyone, authenticated or not" "$code" "200"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
reap
sleep 0.5
# Residue is a failure, and a process is residue. The scratch-clean assertion
# has always checked directories; nothing checked that the run left no server
# behind, and it did -- intermittently, which is the worst way to leave one.
left=0
for pid in $(pgrep -f "gdash_server.bas\|gdash_scheduler.bas" 2>/dev/null); do
    [[ "$(cat /proc/$pid/comm 2>/dev/null)" == "gbasic" ]] && left=$((left + 1))
done
ok "no server or scheduler outlives the run" "$left" "0"
rm -rf "$SCRATCH"
[[ -e "$SCRATCH" ]] && { echo "SCRATCH NOT CLEAN"; exit 1; }
echo "scratch clean: $SCRATCH removed"
echo "e2e: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
