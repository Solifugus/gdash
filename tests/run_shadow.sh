#!/usr/bin/env bash
# gdash — the shadowing refusal, wired.
#
# tests/test_shadow.bas pins the SCAN. This pins the REFUSAL: that each of the
# four gdash entry points actually stops, in its own process, with a message an
# operator can act on.
#
# It also pins the PREMISE, which matters more than the guard does. A bare-name
# `load` does not reach the installed stdlib first: the platform searches the
# loading file's own directory, recursively, and the first match wins, saying
# so only in a stderr warning. The first thing this script does is demonstrate
# that inside a copy of gdash's own module directory -- so if the platform ever
# changes the rule, this suite says the guard is now unnecessary rather than
# quietly guarding against nothing.
#
# Hermetic: no port, no network, no database, no display.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/gsql_owners.sh"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
# A guard that REPORTS but does not EXIT leaves the server serving, and this
# suite hung on exactly that while being mutation-checked. A timeout turns
# "never came back" into an assertion failure that names itself.
RUN(){ timeout 20 "$GBASIC" "$@"; }
export GDASH_GBASIC="$GBASIC"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-shadow-XXXXXX")"
SRC="$SCRATCH/src"
ROOT="$SCRATCH/root"
mkdir -p "$ROOT"
cp -r src "$SRC"

# The suite exports GDASH_SRC for the in-process tests; here it would point the
# guard back at the REAL src/ and every case would pass for the wrong reason.
unset GDASH_SRC

pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }
has(){ if grep -q "$2" "$3" 2>/dev/null; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: <$2> not in $(basename "$3")"; fail=$((fail+1)); fi; }

plant(){   # plant <path> <library-name>
    mkdir -p "$(dirname "$1")"
    printf 'library %s\n    function marker()\n        return "SHADOW WON"\n    end function\nend library\n' "$2" > "$1"
}

echo "--- the premise: BESIDE the loading file wins, BELOW it does not ---"
#
# This changed under gdash and the change is why the premise is asserted at all.
# gdash measured (gbasic 159bc30) that a chart.bas three directories down beat
# the stdlib, silently, and guarded against it. That was reported; Matthew ruled
# on it; and as of the 2026-09-14 rebuild a library below the loading file is
# not used and says so. The deep assertion went red on the next run, which is
# the suite reporting a platform change rather than a gdash defect -- exactly
# what asserting the premise is for.
plant "$SRC/chart.bas" chart
cat > "$SRC/premise_probe.bas" <<'EOF'
program main(args)
    load chart
    print(chart.marker())
end program
EOF
got="$(RUN "$SRC/premise_probe.bas" 2>/dev/null)"
ok "a chart.bas beside the modules is loaded instead of the stdlib" "$got" "SHADOW WON"

# Below it: NOT used, and the platform says so rather than dropping it in
# silence. Both halves are asserted -- that the stray does not win, and that
# the real library is what answered.
rm -f "$SRC/chart.bas"
plant "$SRC/vendor/a/b/chart.bas" chart
got="$(RUN "$SRC/premise_probe.bas" 2>"$SCRATCH/below.err")"
if [[ "$got" == "SHADOW WON" ]]; then
    echo "  FAIL a file three directories down must NOT be used any more"; fail=$((fail+1))
else
    echo "  ok   a file three directories down is not used"; pass=$((pass+1))
fi
has "and the platform says it was not used, rather than dropping it silently" "was NOT used" "$SCRATCH/below.err"

# One level down is the same answer. The rule is beside, not near.
rm -rf "$SRC/vendor"
plant "$SRC/vendor/chart.bas" chart
got="$(RUN "$SRC/premise_probe.bas" 2>/dev/null)"
if [[ "$got" == "SHADOW WON" ]]; then
    echo "  FAIL one directory down must not be used either"; fail=$((fail+1))
else
    echo "  ok   one directory down is not used either"; pass=$((pass+1))
fi
rm -f "$SRC/premise_probe.bas"
rm -rf "$SRC/vendor"

echo "--- a clean module directory starts ---"
RUN "$SRC/gdash_cli.bas" --root "$ROOT" list >"$SCRATCH/clean.out" 2>"$SCRATCH/clean.err"
ok "gdash list runs with nothing planted" "$?" "0"
if grep -q "refusing to start" "$SCRATCH/clean.err"; then
    echo "  FAIL a clean directory refused anyway"; fail=$((fail+1))
else
    echo "  ok   a clean directory refused nothing"; pass=$((pass+1))
fi

echo "--- each entry point refuses ---"
plant "$SRC/crypto.bas" crypto

RUN "$SRC/gdash_cli.bas" --root "$ROOT" list >/dev/null 2>"$SCRATCH/cli.err"
ok "the CLI exits 2" "$?" "2"
has "the CLI says it is refusing" "refusing to start" "$SCRATCH/cli.err"
has "the CLI names the planted file by full path" "$SRC/crypto.bas" "$SCRATCH/cli.err"
has "the CLI names the library it would replace" "would be loaded as 'crypto'" "$SCRATCH/cli.err"

GDASH_ROOT="$ROOT" GDASH_PORT=0 RUN "$SRC/gdash_server.bas" >/dev/null 2>"$SCRATCH/server.err"
ok "the server exits 2 rather than binding" "$?" "2"
has "the server says why" "refusing to start" "$SCRATCH/server.err"

RUN "$SRC/gdash_scheduler.bas" --root "$ROOT" --once >/dev/null 2>"$SCRATCH/sched.err"
ok "the scheduler exits 2" "$?" "2"
has "the scheduler says why" "refusing to start" "$SCRATCH/sched.err"

# The child is given a job file that does not exist. Without the guard that is
# exit 2 with "job file not found"; with it, exit 2 with the refusal -- so the
# MESSAGE is the assertion here, not the code.
RUN "$SRC/gdash_refresh_child.bas" "$SCRATCH/no-such-job" >/dev/null 2>"$SCRATCH/child.err"
ok "the refresh child exits 2" "$?" "2"
has "the refresh child refuses before reading its job" "refusing to start" "$SCRATCH/child.err"

echo "--- and a file BELOW the module directory is not refused ---"
#
# The guard used to walk, and kept walking for a few hours after the platform
# stopped needing it to. Refusing to start over a file the platform will never
# load is a denial of service on a harmless file, and a guard that fires where
# nothing is wrong is how a guard gets switched off.
rm -f "$SRC/crypto.bas"
# ONE LEVEL is the boundary and the realistic one -- `src/vendor/web.bas` is a
# directory layout somebody actually has. A guard that walks only one level
# passes a two-level assertion, which is how the first version of this check
# failed to notice a mutation that reintroduced the false refusal.
for where in "$SRC/vendor/web.bas" "$SRC/vendor/deep/web.bas"; do
    rm -rf "$SRC/vendor"
    plant "$where" web
    RUN "$SRC/gdash_cli.bas" --root "$ROOT" list >/dev/null 2>"$SCRATCH/nested.err"
    ok "gdash still starts with a web.bas at ${where#$SRC/}" "$?" "0"
    if grep -q "refusing to start" "$SCRATCH/nested.err"; then
        echo "  FAIL gdash refused over a file the platform would not have loaded: $where"; fail=$((fail+1))
    else
        echo "  ok   and nothing is refused over it"; pass=$((pass+1))
    fi
done
rm -rf "$SRC/vendor"

echo "--- removing a real shadow lets gdash start again ---"
plant "$SRC/gsql.bas" gsql
RUN "$SRC/gdash_cli.bas" --root "$ROOT" list >/dev/null 2>"$SCRATCH/again1.err"
ok "a shadow beside the modules still stops it" "$?" "2"
rm -f "$SRC/gsql.bas"
RUN "$SRC/gdash_cli.bas" --root "$ROOT" list >/dev/null 2>"$SCRATCH/again.err"
ok "gdash starts once the file is gone" "$?" "0"

wait_for_gsql_owners "$SCRATCH"; rm -rf "$SCRATCH"
if [[ -e "$SCRATCH" ]]; then
    echo "SCRATCH NOT CLEAN: $SCRATCH survived removal" >&2
    exit 1
fi
echo "  shadow: $pass passed, $fail failed (scratch clean)"
[[ $fail -eq 0 ]]
