#!/usr/bin/env bash
# gdash — the shared-nothing property, under more than one worker.
#
# Design §5 says workers share no in-memory state: per-viewer interactivity
# rides request/response, and SSE carries only global events observed through
# the filesystem. Sessions are files and the pin is a cookie BECAUSE of that
# claim. Through GDASH-5 it had never been executed -- every test ran against
# the default `workers: 1` (finding G6-1).
#
# `workers` must be a NUMBER LITERAL in the server block's head (G6-7), so the
# count cannot come from the environment. Rather than commit a second copy of
# the routing table with a different literal -- two sources of truth for
# routing, which gdash refuses everywhere else -- this copies src/ to a scratch
# directory and rewrites the literal there. `load` is script-relative, so the
# copy resolves its own modules; fixtures are cwd-relative, so the run stays
# anchored at the repo root.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"

WORKERS="${GDASH_TEST_WORKERS:-4}"
PORT=8780
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-workers-XXXXXX")"
ROOT="$SCRATCH/root"
SRC="$SCRATCH/src"
mkdir -p "$ROOT/etc" "$ROOT/lib/dashboards/sales" "$ROOT/cache" "$ROOT/log" "$ROOT/run"

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
reap(){
    local pids
    pids="$(pgrep -f "$SRC/gdash_server.bas" 2>/dev/null | grep -v "^$$\$" | tr '\n' ' ')"
    [[ -n "$pids" ]] || return 0
    kill $pids 2>/dev/null
    for i in $(seq 1 20); do
        pgrep -f "$SRC/gdash_server.bas" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    kill -9 $(pgrep -f "$SRC/gdash_server.bas" 2>/dev/null | tr '\n' ' ') 2>/dev/null
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

cp -r src "$SRC"
sed -i "s/server gdash_web( port: $PORT )/server gdash_web( port: $PORT, workers: $WORKERS )/" "$SRC/gdash_server.bas"
if ! grep -q "workers: $WORKERS" "$SRC/gdash_server.bas"; then
    echo "  FAIL could not set the worker count -- the server block's head changed shape" >&2
    exit 1
fi

cp dashboards/sales/draft.json "$ROOT/lib/dashboards/sales/draft.json"
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse":  { "kind": "fixture", "path": "fixtures/orders.json" },
  "regionbook": { "kind": "fixture", "path": "fixtures/regions.json" } }
JSON
printf 'fake-analyst-pw\nfake-analyst-pw\n' | "$GBASIC" src/gdash_cli.bas --root "$ROOT" user add ada --email ada@example.invalid --groups analysts >/dev/null 2>&1
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1

echo "--- $WORKERS workers ---"
GDASH_ROOT="$ROOT" "$GBASIC" --line-buffered "$SRC/gdash_server.bas" > "$SCRATCH/server.log" 2>&1 &
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

# --- SSE: a global event observed through the filesystem ------------------
#
# The claim, in one assertion: four streams held open on four different
# workers must all see a change made by a FIFTH process that shares nothing
# with any of them but a directory.
# A BARE `wait` HERE WAITS FOR THE SERVER, which never exits. The stream pids
# are named explicitly for that reason -- and named into their own array,
# because `pids` is still holding the render curls.
# TWO streams, not more. Two is enough to show that a stream on one worker
# sees a change made by a process that is not a worker at all, which is the
# claim. Larger counts were tried and could not be established reliably from a
# shell -- see the finding on the stream ceiling, which is GDASH-8's to settle
# alongside the worker-sizing documentation the plan already calls for.
#
# ESTABLISHING the streams is retried; OBSERVING the event is not. Opening two
# concurrent streams fails outright perhaps one attempt in four even with
# workers to spare, and that is a setup flake rather than the property under
# test -- so it is retried, and the retry count is reported. If it were the
# property, retrying would be cheating.
attempt=0
opened=0
while [[ $attempt -lt 4 && $opened -lt 2 ]]; do
    attempt=$((attempt + 1))
    rm -f "$SCRATCH"/sse1.txt "$SCRATCH"/sse2.txt
    touch "$SCRATCH/sse1.txt" "$SCRATCH/sse2.txt"
    spids=(); for k in 1 2; do
        curl -s -N --max-time 12 "http://127.0.0.1:$PORT/d/sales/events" > "$SCRATCH/sse$k.txt" 2>/dev/null & spids+=($!)
    done
    # Wait for the streams, not for the clock: a stream that connects AFTER the
    # refresh reads the new version as its baseline and never reports a change,
    # so the test would fail for a reason unrelated to what it tests. This is
    # the lesson of G5-8, where an open port was mistaken for a working service.
    for i in $(seq 1 24); do
        opened=0
        for k in 1 2; do grep -q "^event: hello" "$SCRATCH/sse$k.txt" 2>/dev/null && opened=$((opened+1)); done
        [[ $opened -eq 2 ]] && break
        sleep 0.25
    done
    if [[ $opened -lt 2 ]]; then
        kill "${spids[@]}" 2>/dev/null; wait "${spids[@]}" 2>/dev/null
    fi
done
ok "two concurrent streams open (attempt $attempt of at most 4)" "$opened" "2"

python3 -c "
import json,sys
p='$ROOT/etc/connections.json'
c=json.load(open(p)); c['warehouse']['path']='fixtures/orders_moved.json'; json.dump(c,open(p,'w'))"
"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales orders >/dev/null 2>&1
wait "${spids[@]}" 2>/dev/null
saw=0
for k in 1 2; do grep -q '^data: refresh' "$SCRATCH/sse$k.txt" && saw=$((saw+1)); done
ok "every concurrent stream sees a refresh performed by another process" "$saw" "2"

# A leaked worker is residue, and residue is a failure. The suite already
# asserts that it leaves no files behind; it now asserts that it leaves no
# processes behind either.
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
reap
left="$(pgrep -f "$SRC/gdash_server.bas" 2>/dev/null | wc -l)"
ok "no server process outlives the run" "$left" "0"

echo "---"
echo "workers: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
