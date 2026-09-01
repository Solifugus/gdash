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
curl -s -N --max-time 8 "http://127.0.0.1:$PORT/d/timed/events" > "$SCRATCH/sse3.txt" &
SSE3=$!
sleep 1
"$GBASIC" src/gdash_cli.bas --root "$ROOT" publish timed >/dev/null 2>&1
sleep 2.5
kill $SSE3 2>/dev/null; wait $SSE3 2>/dev/null
has "$(cat "$SCRATCH/sse3.txt")" "data: publish" "a publish is announced over SSE"
hasnt "$(cat "$SCRATCH/sse3.txt")" "data: refresh" "and is NOT announced as a data refresh"
has "$fresh" "gdash-notice" "the page carries the banner the notice reveals"
has "$fresh" "hidden" "hidden until there is something to say"

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
has "$mine" "gdash-value-number" "with a figure, which an empty result would not render"

# The admin has no email, so the same query returns nothing for them. Same
# dashboard, same dataset, different rows -- design §5's whole claim.
boss="$(curl -s -b "$jarC" --max-time 10 "http://127.0.0.1:$PORT/d/team")"
hasnt "$boss" "Only for ada" "and renders nothing for an identity it does not match"

# ...and asking to be someone else changes nothing, because user_* is
# injected from the session and never merged from the client.
spoof="$(curl -s -b "$jarC" --max-time 10 "http://127.0.0.1:$PORT/d/team?user_email=ada@example.invalid")"
hasnt "$spoof" "Only for ada" "a client-supplied user_email is ignored, not honoured"

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
rm -rf "$SCRATCH"
[[ -e "$SCRATCH" ]] && { echo "SCRATCH NOT CLEAN"; exit 1; }
echo "scratch clean: $SCRATCH removed"
echo "e2e: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
