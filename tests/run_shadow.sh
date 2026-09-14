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

echo "--- the premise: a stray file in the module directory wins over the stdlib ---"
plant "$SRC/chart.bas" chart
cat > "$SRC/premise_probe.bas" <<'EOF'
program main(args)
    load chart
    print(chart.marker())
end program
EOF
got="$(RUN "$SRC/premise_probe.bas" 2>/dev/null)"
ok "a chart.bas beside the modules is loaded instead of the stdlib" "$got" "SHADOW WON"

# And three directories down, which is the shape that makes a directory listing
# an inadequate review.
rm -f "$SRC/chart.bas"
plant "$SRC/vendor/a/b/chart.bas" chart
got="$(RUN "$SRC/premise_probe.bas" 2>/dev/null)"
ok "and so is one three directories down" "$got" "SHADOW WON"
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

echo "--- and nested, which is what makes the walk recursive ---"
rm -f "$SRC/crypto.bas"
plant "$SRC/vendor/deep/web.bas" web
RUN "$SRC/gdash_cli.bas" --root "$ROOT" list >/dev/null 2>"$SCRATCH/nested.err"
ok "a nested web.bas is refused too" "$?" "2"
has "and the nested path is named in full" "$SRC/vendor/deep/web.bas" "$SCRATCH/nested.err"

echo "--- removing it lets gdash start again ---"
rm -rf "$SRC/vendor"
RUN "$SRC/gdash_cli.bas" --root "$ROOT" list >/dev/null 2>"$SCRATCH/again.err"
ok "gdash starts once the file is gone" "$?" "0"

rm -rf "$SCRATCH"
if [[ -e "$SCRATCH" ]]; then
    echo "SCRATCH NOT CLEAN: $SCRATCH survived removal" >&2
    exit 1
fi
echo "  shadow: $pass passed, $fail failed (scratch clean)"
[[ $fail -eq 0 ]]
