#!/usr/bin/env bash
# gdash — the races, produced rather than described.
#
# Three pieces of gdash exist because two things can happen at once, and until
# now none of them had ever had two things happen at once:
#
#   * the refresh lock -- a blocking flock plus a state re-read inside it,
#     written for a race nobody had run (gdash_refresh, finding G2-6);
#   * the publish swap -- a single POSIX rename that design §7 says a live
#     reader can never catch half-done;
#   * first-use file creation, which GDASH-6 already fixed for the CSRF secret.
#
# Loopback only, fixture source, no database, no display.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"

PORT=8780
port_must_be_free "$PORT"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-races-XXXXXX")"
ROOT="$SCRATCH/root"
mkdir -p "$ROOT/etc" "$ROOT/lib/dashboards/sales" "$ROOT/cache" "$ROOT/log" "$ROOT/run"

pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }

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
cleanup(){ reap; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# A fixed port that is already occupied produces a failure with nothing to do
# with the thing being tested. Say so instead of failing obscurely.
port_must_be_free(){
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; then
        echo "port $1 is already in use -- something else is serving on it." >&2
        echo "  stop it first; this suite needs the port and will not kill a stranger." >&2
        exit 2
    fi
}


cp dashboards/sales/draft.json "$ROOT/lib/dashboards/sales/draft.json"
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse":  { "kind": "fixture", "path": "fixtures/orders.json" },
  "regionbook": { "kind": "fixture", "path": "fixtures/regions.json" } }
JSON

"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1
baseline="$("$GBASIC" tests/race_check.bas "$ROOT" sales orders 2>&1)"
base_rows="${baseline%% *}"
# Compared against what the fixture actually staged rather than a number typed
# here: the assertion is that the pile-up changes nothing, not that the fixture
# has some particular size.
ok "the dataset reads before anything races" "${base_rows:0:5}" "rows="

echo "--- eight refreshes of one dataset, at once ---"
#
# There is no non-blocking advisory lock (G2-6), so the lock SERIALIZES and the
# state is re-read after acquiring it. What must come out the other side is one
# coherent dataset -- never a torn one, and never a staging file left behind.
pids=(); for i in $(seq 1 8); do
    "$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales orders > "$SCRATCH/ref$i.txt" 2>&1 & pids+=($!)
done
wait "${pids[@]}" 2>/dev/null

failed_refresh=0
for i in $(seq 1 8); do grep -qiE "error|failed|traceback" "$SCRATCH/ref$i.txt" && failed_refresh=$((failed_refresh + 1)); done
ok "no concurrent refresh reports an error" "$failed_refresh" "0"

after="$("$GBASIC" tests/race_check.bas "$ROOT" sales orders 2>&1)"
ok "the dataset is still one coherent version afterwards" "${after%% *}" "$base_rows"

# A swap that lost a race would leave its staging file behind, and the next
# refresh would inherit it.
staging="$(find "$ROOT" -name '*.staging*' 2>/dev/null | wc -l)"
ok "no staging file survives the pile-up" "$staging" "0"

# ...and reads the same way twice in a row, which a torn file would not.
again="$("$GBASIC" tests/race_check.bas "$ROOT" sales orders 2>&1)"
ok "and reads identically on a second look" "${again%% *}" "$base_rows"

echo "--- publishing under a live reader ---"
"$GBASIC" src/gdash_cli.bas --root "$ROOT" publish sales >/dev/null 2>&1
GDASH_ROOT="$ROOT" "$GBASIC" --line-buffered src/gdash_server.bas > "$SCRATCH/server.log" 2>&1 &
SRV=$!
serving=""
for i in $(seq 1 80); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null)" == "200" ]] && { serving=yes; break; }
    sleep 0.25
done
ok "the server is answering" "$serving" "yes"

# Design §7: publish repoints `current` with one rename, so a viewer mid-render
# sees the old version or the new one. Never a dashboard that half-exists.
( for k in $(seq 1 6); do "$GBASIC" src/gdash_cli.bas --root "$ROOT" publish sales >/dev/null 2>&1; done ) &
PUB=$!
rm -f "$SCRATCH"/read*.code
rpids=(); for k in $(seq 1 20); do
    curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:$PORT/d/sales" > "$SCRATCH/read$k.code" 2>/dev/null & rpids+=($!)
done
wait "${rpids[@]}" 2>/dev/null
wait "$PUB" 2>/dev/null

bad="$(cat "$SCRATCH"/read*.code | tr -d '\n' | sed 's/200//g')"
ok "every read during a publish storm saw a whole dashboard" "$bad" ""

snaps="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" snapshots sales 2>&1 | grep -c '^[ *] ')"
ok "and every publish produced a snapshot" "$snaps" "7"

kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
reap
sleep 0.5
left=0
for pid in $(pgrep -f "gdash_server.bas" 2>/dev/null); do
    [[ "$(cat /proc/$pid/comm 2>/dev/null)" == "gbasic" ]] && left=$((left + 1))
done
ok "no server outlives the run" "$left" "0"

echo "---"
echo "races: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
