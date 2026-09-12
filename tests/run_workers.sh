#!/usr/bin/env bash
# gdash — the shared-nothing property, under more than one worker.
#
# Design §5 says workers share no in-memory state: per-viewer interactivity
# rides request/response, and SSE carries only global events observed through
# the filesystem. Sessions are files and the pin is a cookie BECAUSE of that
# claim. Through GDASH-5 it had never been executed -- every test ran against
# the default `workers: 1` (finding G6-1).
#
# The worker count is CONFIGURATION now (gbasic ca5df46, gdash uses
# web.configure), so this suite sets GDASH_WORKERS and runs the real
# src/gdash_server.bas. It used to copy src/ to a scratch directory and rewrite
# a literal there, because the head took literals only and committing a second
# copy of the routing table would have been two sources of truth for routing
# (finding G6-7). That workaround is gone.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"

WORKERS="${GDASH_TEST_WORKERS:-4}"
PORT=8780
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-workers-XXXXXX")"
ROOT="$SCRATCH/root"
mkdir -p "$ROOT/etc" "$ROOT/lib/dashboards/sales" "$ROOT/cache" "$ROOT/log" "$ROOT/run"
SERVER="src/gdash_server.bas"

pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }

# COUNT OCCURRENCES, NOT LINES. /whoami answers compact JSON with no trailing
# newline, so N concurrent responses land on ONE line: `grep -c` reports 1
# however many arrived, and a greedy `sed` yields only the last token. Both
# read as "one worker answered, one secret" -- a green result from a test that
# measured nothing. This is finding G6-9, and it happened in the first draft of
# this very file.
n_responses(){ grep -o '"authenticated"' "$1" 2>/dev/null | wc -l; }
n_secrets(){ grep -o '"csrf":"[^"]*"' "$1" 2>/dev/null | sort -u | wc -l; }

# Killing the supervisor does NOT take the workers with it: they are its
# children, spawned through process.self(), and at least one survives every
# time. A leaked worker holds the port and keeps a deleted root alive, which
# is residue the scratch-clean assertion never looked for -- it checks
# directories, not processes.
#
# The scratch path is in each worker's command line and is unique to this run,
# so it is a safe pattern to match. `pkill -f gdash_server.bas` would not be:
# it matches the shell that launched this script too, and killing that reads
# as a mysterious exit 144.
# Kill only processes actually NAMED gbasic. A bare `pkill -f gdash_server.bas`
# also matches the shell that launched this script, and killing that produces a
# mysterious exit code and no output at all.
reap(){
    local pid
    for pid in $(pgrep -f "gdash_server.bas" 2>/dev/null); do
        [[ "$(cat /proc/$pid/comm 2>/dev/null)" == "gbasic" ]] || continue
        kill "$pid" 2>/dev/null
    done
}

cleanup(){
    [[ -n "${SRV:-}" ]] && kill "$SRV" 2>/dev/null
    wait "$SRV" 2>/dev/null
    reap
    if [[ $fail -gt 0 && -s "$SCRATCH/server.log" ]]; then
        echo "--- server log (last 20 lines) ---"
        tail -20 "$SCRATCH/server.log"
    fi
    [[ "${GDASH_KEEP:-0}" == "1" ]] && { echo "kept: $SCRATCH"; return; }
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

cp dashboards/sales/draft.json "$ROOT/lib/dashboards/sales/draft.json"
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse":  { "kind": "fixture", "path": "fixtures/orders.json" },
  "regionbook": { "kind": "fixture", "path": "fixtures/regions.json" } }
JSON
printf 'fake-analyst-pw\nfake-analyst-pw\n' | "$GBASIC" src/gdash_cli.bas --root "$ROOT" user add ada --email ada@example.invalid --groups analysts >/dev/null 2>&1
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1

echo "--- $WORKERS workers ---"
GDASH_ROOT="$ROOT" GDASH_WORKERS="$WORKERS" "$GBASIC" --line-buffered "$SERVER" > "$SCRATCH/server.log" 2>&1 &
SRV=$!

# READINESS IS SHAPE-DEPENDENT (finding G6-2). At `workers: 1` serve returns
# and gdash prints its own "listening" line; at `workers: N` serve becomes the
# supervisor, prints `PORT <n>` itself, and does not return until drain -- so
# the gdash line never appears at startup. A readiness check that knows only
# one shape hangs forever in the other.
ready=""
for i in $(seq 1 80); do
    if grep -qE "listening|^PORT " "$SCRATCH/server.log" 2>/dev/null; then ready=yes; break; fi
    sleep 0.25
done
ok "the server announces readiness in whichever shape serve took" "$ready" "yes"

# ...BUT NEITHER LINE MEANS THE SERVICE IS READY. Under `workers: N` the
# supervisor prints `PORT <n>` as soon as the socket is BOUND, and only then
# spawns the workers. A connection arriving in that window is accepted by the
# kernel backlog and answered by nobody, so a log-line readiness check reports
# ready while requests hang -- and the window grows with the worker count.
# Readiness is a request that got an answer. This is the third time in this
# project that "the port is open" has been confused with "the service works"
# (G4-10, G5-8), and the first time it was the harness rather than the product.
serving=""
for i in $(seq 1 80); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null)" == "200" ]]; then
        serving=yes; break
    fi
    sleep 0.25
done
ok "and a request actually gets answered" "$serving" "yes"

# Polled, not snapshotted: the supervisor binds and prints before it has
# finished spawning, so a single sample races the pool.
n_workers=0
for i in $(seq 1 60); do
    # `pgrep -c` prints 0 AND exits 1 when nothing matches, so the usual
    # `|| echo 0` fallback appends a second line and the variable stops being
    # a number. Count lines from a plain pgrep instead.
    n_workers="$(pgrep -x gbasic 2>/dev/null | wc -l)"
    [[ "$n_workers" -gt "$WORKERS" ]] && break
    sleep 0.25
done
if [[ "$n_workers" -gt "$WORKERS" ]]; then
    echo "  ok   $n_workers processes are serving (a supervisor plus $WORKERS workers)"; pass=$((pass+1))
else
    echo "  FAIL only $n_workers processes, wanted more than $WORKERS"; fail=$((fail+1))
fi

# --- a session is a file, so every worker sees it -------------------------
jar="$SCRATCH/ada.txt"
form="$(curl -s -c "$jar" --max-time 10 "http://127.0.0.1:$PORT/login")"
tok="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' <<<"$form")"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" --max-time 10 -X POST -d "csrf=$tok&user=ada&pass=fake-analyst-pw" "http://127.0.0.1:$PORT/login")"
ok "sign-in works with a pre-login session minted on some other worker" "$code" "303"

seen=0
for i in $(seq 1 30); do
    grep -q '"user":"ada"' <<<"$(curl -s -b "$jar" --max-time 10 "http://127.0.0.1:$PORT/whoami")" && seen=$((seen+1))
done
ok "the session is seen on every worker it lands on" "$seen" "30"

# --- one CSRF secret, not one per worker (finding G6-3) -------------------
distinct="$(for i in $(seq 1 12); do sed -n 's/.*"csrf":"\([^"]*\)".*/\1/p' <<<"$(curl -s -b "$jar" --max-time 10 "http://127.0.0.1:$PORT/whoami")"; done | sort -u | wc -l)"
ok "every worker mints the same CSRF token for one session" "$distinct" "1"

# The race G6-3 fixed: remove the secret and let several workers meet the
# empty-file case at once. Without the lock, two workers each mint a secret and
# each return its OWN, so a token minted on one is refused by another.
#
# THIS IS PROBABILISTIC. Against the pre-fix code it reproduced in 1 round out
# of 5, so one round would be a test that passes 80% of the time on broken
# code. Six rounds is roughly a three-in-four chance of catching a regression,
# which is a net rather than a guarantee; the guarantee is structural, in
# secret_of taking the lock and re-reading inside it.
for round in 1 2 3 4 5 6; do
    rm -f "$ROOT/etc/secret"
    pids=(); for i in $(seq 1 24); do curl -s -b "$jar" --max-time 12 "http://127.0.0.1:$PORT/whoami" & pids+=($!); done > "$SCRATCH/race$round.txt" 2>/dev/null
    wait "${pids[@]}" 2>/dev/null
    got="$(n_responses "$SCRATCH/race$round.txt")"
    ok "round $round: all 24 concurrent first-requests were answered" "$got" "24"
    ok "round $round: and agreed on one freshly minted secret" "$(n_secrets "$SCRATCH/race$round.txt")" "1"
done

# --- concurrent renders ---------------------------------------------------
# Each curl writes its own file. A bare `wait` inside a command substitution
# waits on the SERVER too, and naming the pids there reports them as "not a
# child of this shell" and spins; the results come back through the filesystem
# instead.
rm -f "$SCRATCH"/render*.code
pids=(); for i in $(seq 1 8); do
    curl -s -o /dev/null -w '%{http_code}' -b "$jar" --max-time 20 "http://127.0.0.1:$PORT/d/sales" > "$SCRATCH/render$i.code" 2>/dev/null & pids+=($!)
done
wait "${pids[@]}" 2>/dev/null
ok "eight concurrent renders all succeed" "$(cat "$SCRATCH"/render*.code | tr -d '\n')" "200200200200200200200200"

# --- a global event observed through the filesystem ----------------------
#
# The claim, in one assertion: viewers spread across all four workers must all
# see a change made by a FIFTH process that shares nothing with any of them
# but a directory.
#
# This used to be two held SSE streams, and two was the most that could be
# established reliably -- because a held stream OCCUPIES a worker, so the
# third stream on a four-worker server was competing with the suite's own
# requests. That was recorded as a flake and retried. It was not a flake: it
# was the ceiling, showing through the test that was meant to measure past it
# (GDASH-11). With the poll in the browser there is no ceiling to work around
# and no retry loop to explain, so the count goes up rather than down.
before="$(curl -s --max-time 10 "http://127.0.0.1:$PORT/d/sales/version")"
python3 -c "
import json,sys
p='$ROOT/etc/connections.json'
c=json.load(open(p)); c['warehouse']['path']='fixtures/orders_moved.json'; json.dump(c,open(p,'w'))"
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales orders >/dev/null 2>&1

# Eight at once against four workers: every worker answers, and each answers
# from the filesystem rather than from anything it remembers.
vpids=(); for k in $(seq 1 8); do
    curl -s --max-time 20 "http://127.0.0.1:$PORT/d/sales/version" > "$SCRATCH/ver$k.txt" 2>/dev/null & vpids+=($!)
done
wait "${vpids[@]}" 2>/dev/null
saw=0
for k in $(seq 1 8); do
    [[ "$(cat "$SCRATCH/ver$k.txt" 2>/dev/null)" != "$before" ]] && [[ -s "$SCRATCH/ver$k.txt" ]] && saw=$((saw+1))
done
ok "every worker reports a refresh performed by a process that is not a worker" "$saw" "8"

# A leaked worker is residue, and residue is a failure. The suite already
# asserts that it leaves no files behind; it now asserts that it leaves no
# processes behind either.
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
reap
left="$(pgrep -f "$SERVER" 2>/dev/null | wc -l)"
ok "no server process outlives the run" "$left" "0"

echo "---"
echo "workers: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
