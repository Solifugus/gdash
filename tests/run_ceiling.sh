#!/usr/bin/env bash
# gdash concurrency ceiling: how many viewers does one gdash serve?
#
# This suite exists because for ten phases the answer was "one fewer than it
# has workers", the default worker count is one, and nothing failed. The
# ceiling was recorded (G6-10, G8-9) as a number to be aware of rather than
# measured as a thing a person would hit, and a person opening two tabs hits
# it immediately.
#
# Measured at GDASH-11 step 0, before the fix, at gbasic ca5df46:
#
#   workers=1  streams=0   baseline=200  next request=200 after 0.1s
#   workers=1  streams=1   baseline=200  next request=000 after 5.0s
#   workers=2  streams=2   baseline=200  next request=000 after 5.0s
#   workers=4  streams=4   baseline=200  next request=000 after 5.0s
#
# Not "slower". Nothing served at all, for as long as the tab stayed open.
#
# The CAUSE named in GDASH-11 was wrong and is corrected in G11-13: this is a
# property of a handler that loops in sleep() and never returns, not of
# `stream`. A stream handler that returns parks the connection and frees its
# worker. gdash polls anyway, because a parked stream is reachable only from
# the worker that accepted it and gdash must run more than one worker.
#
# The assertions below are unaffected -- they are about what the shipped page
# does and whether viewers are served, not about why the old shape failed.
#
# Everything here runs at the DEFAULT worker count -- GDASH_WORKERS is unset
# on purpose -- because the default is what someone gets when they run the
# server to try it, and a fix that only holds at four workers is not a fix.
#
# Still hermetic: loopback only, fixture source, no database, no display.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/gsql_owners.sh"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"

# A gdash server that was ALREADY RUNNING when this suite started is not ours,
# and killing it is not the suite's business. The sweep below matches by NAME
# because the supervisor's workers are not $! -- so it cannot simply kill the pid
# it started -- and that made it collateral: running the suite silently killed a
# demo server somebody had deliberately started, after colliding with it on the
# fixed port. The collision looked like a flake; the kill looked like nothing at
# all (G19-1).
PREEXISTING=" $(pgrep -f "gdash_server.bas\|gdash_scheduler.bas" 2>/dev/null | tr '\n' ' ') "
reap(){
    local pid
    for pid in $(pgrep -f "gdash_server.bas" 2>/dev/null); do
        [[ "$(cat /proc/$pid/comm 2>/dev/null)" == "gbasic" ]] || continue
        [[ "$PREEXISTING" == *" $pid "* ]] && continue
        kill "$pid" 2>/dev/null
    done
}
trap reap EXIT

# A fixed port that is already occupied produces a failure with nothing to do
# with the thing being tested. Say so instead of failing obscurely.
port_must_be_free(){
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; then
        echo "port $1 is already in use -- something else is serving on it." >&2
        echo "  stop it first; this suite needs the port and will not kill a stranger." >&2
        exit 2
    fi
}


SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-ceiling-XXXXXX")"
ROOT="$SCRATCH/root"
PORT=8783
port_must_be_free "$PORT"
pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }
has(){ if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3: <$2> not found"; fail=$((fail+1)); fi; }
hasnt(){ if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3: <$2> should be absent"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }

mkdir -p "$ROOT/lib/dashboards/sales" "$ROOT/etc" "$ROOT/cache" "$ROOT/log" "$ROOT/run"
cp dashboards/sales/draft.json "$ROOT/lib/dashboards/sales/draft.json"
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse":  { "kind": "fixture", "path": "fixtures/orders.json" },
  "regionbook": { "kind": "fixture", "path": "fixtures/regions.json" } }
JSON
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1

echo "--- the default worker count ---"
# GDASH_WORKERS deliberately unset: this is `gdash-server` as a person runs it.
env -u GDASH_WORKERS GDASH_ROOT="$ROOT" GDASH_PORT="$PORT" \
    "$GBASIC" --line-buffered src/gdash_server.bas > "$SCRATCH/server.log" 2>&1 &
for i in $(seq 1 80); do grep -qE "listening|^PORT " "$SCRATCH/server.log" 2>/dev/null && break; sleep 0.25; done
has "$(cat "$SCRATCH/server.log")" "listening" "server started on its default worker count"

page="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
has "$page" "gdash-value" "and serves a dashboard"

echo "--- what the page asks the browser to do ---"
# The ceiling was never a platform limit; it was a consequence of what the
# page was told to open. So the first assertions are about the instruction,
# not about the server: a page that opens a long-lived connection puts the
# ceiling back however well the server behaves.
hasnt "$page" "EventSource" "the page opens no event stream"
hasnt "$page" "WebSocket" "nor a socket by another name"
has "$page" "setInterval" "it polls on a timer instead"
has "$page" "location.pathname+'/version'" "for the two facts the stream used to carry"

# And the route that pinned a worker is gone, so a viewer cannot reach the
# old behaviour by asking for it directly.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/sales/events")"
ok "the stream route no longer exists" "$code" "404"

echo "--- viewers, behaving the way the page tells them to ---"
# Six simulated viewers, each polling /version the way the shim does, at the
# shim's interval divided by ten so that six viewers generate the request rate
# of sixty. Under the old design ONE of these -- had it held a stream -- was
# enough to stop everything.
VIEWERS=6
vpids=()
for k in $(seq 1 $VIEWERS); do
    ( end=$((SECONDS + 12))
      while [[ $SECONDS -lt $end ]]; do
          curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$PORT/d/sales/version"
          sleep 0.5
      done ) &
    vpids+=($!)
done
# Let the pollers get going, so the measurement below lands while they are
# actually in flight rather than before the first one has sent anything.
for i in $(seq 1 20); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/d/sales/version")" == "200" ]] && break
    sleep 0.25
done

# The thing a person would notice: does a seventh viewer get their dashboard,
# and how long do they wait for it? A page render is the most expensive thing
# gdash does -- every visual queries -- so this is the honest worst case.
slowest=0
codes=""
for k in 1 2 3; do
    t0=$(date +%s%N)
    codes="$codes$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/d/sales")"
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    [[ $ms -gt $slowest ]] && slowest=$ms
done
ok "a further viewer is served while six are polling, on one worker" "$codes" "200200200"

# A slicer is the interactive path, and it is a POST -- so it proves the
# non-idempotent route is reachable under load too, not just the page.
resp="$(curl -s --max-time 10 -X POST -H 'content-type: application/json' -d '{"region":"east"}' "http://127.0.0.1:$PORT/d/sales/params")"
has "$resp" '"by_month"' "and a slicer still round-trips under the same load"

for k in "${vpids[@]}"; do kill "$k" 2>/dev/null; done
for k in "${vpids[@]}"; do wait "$k" 2>/dev/null; done

# A threshold, not a stopwatch: this is a correctness assertion about whether
# the server is responsive, and it has to survive a loaded CI machine. The
# failure it guards against is 5000ms-and-no-answer, not 300ms-versus-400ms.
if [[ $slowest -lt 4000 ]]; then
    echo "  ok   and waited ${slowest}ms at worst, not for a worker to be released"
    pass=$((pass+1))
else
    echo "  FAIL a viewer waited ${slowest}ms with six others polling"
    fail=$((fail+1))
fi

echo "--- nothing is left holding anything ---"
# Residue is a failure, and a process is residue. Counted the same way the
# reaper kills: by /proc/PID/comm, because `pgrep -f` also matches anything
# else that merely mentions the script -- this script included.
reap
left=1
for i in $(seq 1 40); do
    left=0
    for pid in $(pgrep -f "gdash_server.bas" 2>/dev/null); do
        [[ "$(cat /proc/$pid/comm 2>/dev/null)" == "gbasic" ]] && left=$((left + 1))
    done
    [[ $left -eq 0 ]] && break
    sleep 0.25
done
ok "no server outlives the run" "$left" "0"

wait_for_gsql_owners "$SCRATCH"; rm -rf "$SCRATCH"
if [[ -e "$SCRATCH" ]]; then
    echo "SCRATCH NOT CLEAN: $SCRATCH survived removal" >&2
    fail=$((fail+1))
else
    echo "scratch clean: $SCRATCH removed"
fi

echo "ceiling: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
