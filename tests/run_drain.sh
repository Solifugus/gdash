#!/usr/bin/env bash
# gdash drain: does a restart finish the requests it is already serving?
#
# Operations §7 promises it does, and that promise was measured once by hand
# during GDASH-8 and then written down. A measurement that is written down and
# never re-run is a claim, and this one sits on a platform code path that has
# since changed: gbasic e56daa0 fixed a program with a server and a live timer
# never exiting on SIGTERM at all. gdash uses no timer and was not the victim,
# but a promise about draining deserves a test rather than a memory.
#
# The slow request is a recursive CTE in the VISUAL query -- ordinary SQL, no
# artificial hook in the server, so what drains is a real page render doing
# real work. Roughly a second per four million rows on this machine.
#
# Still hermetic: loopback only, fixture source, no database, no display.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"

reap(){
    local pid
    for pid in $(pgrep -f "gdash_server.bas" 2>/dev/null); do
        [[ "$(cat /proc/$pid/comm 2>/dev/null)" == "gbasic" ]] || continue
        kill -9 "$pid" 2>/dev/null
    done
}
trap reap EXIT

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-drain-XXXXXX")"
ROOT="$SCRATCH/root"
PORT=8785
pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }
has(){ if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3: <$2> not found"; fail=$((fail+1)); fi; }

mkdir -p "$ROOT/lib/dashboards/slow" "$ROOT/etc" "$ROOT/cache" "$ROOT/log" "$ROOT/run"
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse": { "kind": "fixture", "path": "fixtures/orders.json" } }
JSON

# One dataset so the staged database exists, and one visual whose query takes
# seconds. The marker in the title is what proves the WHOLE response came
# back rather than a truncated prefix.
python3 - "$ROOT" <<'PYEOF'
import json,sys
rec = {
 "format": 1, "name": "slow", "title": "Drain Marker", "access": "open",
 "datasets": { "orders": { "profile": "warehouse", "refresh": "manual",
                           "sql": "select region, month, amount from sales.orders" } },
 "visuals": { "slowcount": {
     "dataset": "orders",
     "sql": "with recursive c(x) as (select 1 union all select x+1 from c where x < 40000000) select count(*) as n from c",
     "encoding": { "mark": "value", "value": "n", "title": "Counted" } } },
 "tabs": [ { "name": "T", "layout": { "vert": [ { "visual": "slowcount" } ] } } ]
}
json.dump(rec, open(sys.argv[1] + "/lib/dashboards/slow/draft.json", "w"), indent=2)
PYEOF

"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh slow >/dev/null 2>&1

# How slow is slow here? Measured rather than assumed, because the assertion
# below depends on SIGTERM landing WHILE a request is in flight, and a request
# that has already finished proves nothing about draining.
t0=$(date +%s%N)
curl -s -o /dev/null --max-time 60 "http://127.0.0.1:$PORT/d/slow" 2>/dev/null
warm=0

drain_test(){ # $1 = worker count
    local W="$1" srvpid elapsed
    reap; sleep 0.4
    GDASH_WORKERS="$W" GDASH_ROOT="$ROOT" GDASH_PORT="$PORT" \
        "$GBASIC" --line-buffered src/gdash_server.bas > "$SCRATCH/server$W.log" 2>&1 &
    srvpid=$!
    for i in $(seq 1 80); do grep -qE "listening|^PORT " "$SCRATCH/server$W.log" 2>/dev/null && break; sleep 0.25; done

    # Time one render first, so the SIGTERM below is known to land mid-flight.
    t0=$(date +%s%N)
    curl -s -o /dev/null --max-time 60 "http://127.0.0.1:$PORT/d/slow"
    t1=$(date +%s%N)
    local render_ms=$(( (t1 - t0) / 1000000 ))

    rm -f "$SCRATCH/drain$W.txt"
    curl -s --max-time 60 "http://127.0.0.1:$PORT/d/slow" > "$SCRATCH/drain$W.txt" 2>/dev/null &
    local cpid=$!

    # A second into a render that takes several: in flight for certain.
    sleep 1
    kill -TERM "$srvpid" 2>/dev/null
    local term_at=$(date +%s%N)

    wait "$cpid" 2>/dev/null
    local body; body="$(cat "$SCRATCH/drain$W.txt" 2>/dev/null)"

    if [[ $render_ms -lt 2000 ]]; then
        echo "  FAIL the slow render took only ${render_ms}ms at workers=$W -- SIGTERM may not have landed in flight"
        fail=$((fail+1))
    else
        echo "  ok   the render takes ${render_ms}ms at workers=$W, so SIGTERM lands mid-flight"
        pass=$((pass+1))
    fi

    has "$body" "Drain Marker" "a request in flight when SIGTERM arrives completes, at workers=$W"
    has "$body" "</html>" "and completes WHOLE, not truncated, at workers=$W"

    # And the process must actually go. This is the half that a live timer
    # used to break: the server drained and then held the event loop open
    # forever (gbasic e56daa0).
    local gone=0
    for i in $(seq 1 80); do
        if ! kill -0 "$srvpid" 2>/dev/null; then gone=1; break; fi
        sleep 0.25
    done
    local exit_ms=$(( ($(date +%s%N) - term_at) / 1000000 ))
    ok "the server exits after draining, at workers=$W" "$gone" "1"
    if [[ $gone -eq 1 && $exit_ms -lt 20000 ]]; then
        echo "  ok   and exits promptly (${exit_ms}ms), not holding the event loop open"
        pass=$((pass+1))
    elif [[ $gone -eq 1 ]]; then
        echo "  FAIL the server took ${exit_ms}ms to exit at workers=$W"
        fail=$((fail+1))
    fi
    reap; sleep 0.3
}

echo "--- draining at one worker ---"
drain_test 1
echo "--- draining at four ---"
drain_test 4

rm -rf "$SCRATCH"
if [[ -e "$SCRATCH" ]]; then
    echo "SCRATCH NOT CLEAN: $SCRATCH survived removal" >&2
    fail=$((fail+1))
else
    echo "scratch clean: $SCRATCH removed"
fi

echo "drain: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
