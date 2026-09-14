#!/usr/bin/env bash
# gdash hermetic suite.
#
# Runs under --root in a temp dir: no network, no live database, no display,
# no installed system state. Anything needing a live service is a separate
# opt-in runner gated on an environment variable (GDASH_POSTGRES_TEST=1).
#
# Every run ends with a scratch-clean assertion.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"

if [[ ! -x "$GBASIC" ]]; then
    echo "gbasic interpreter not found at: $GBASIC" >&2
    echo "set GDASH_GBASIC to its path" >&2
    exit 2
fi

# Tests reference repo-relative fixtures, so the run is anchored at the root
# rather than depending on where the runner was invoked from.
cd "$HERE/.."

# The refresh parent starts a child interpreter; it finds it here.
export GDASH_GBASIC="$GBASIC"
# A test program runs out of tests/, but the refresh child lives in src/. In an
# install they sit together and gdash finds the child beside itself; here the
# override says where it actually is (finding G8-2).
export GDASH_SRC="$HERE/../src"

# The interpreter is built from a sibling repo that is under active
# development, and a rebuild mid-run replaces this binary underneath us. That
# produces failures with no useful output -- a CLI invocation simply exiting 1
# -- which look like gdash bugs and are not. Recorded at both ends so the run
# can say so instead of leaving somebody to debug a phantom.
# THE STDLIB COUNTS TOO. gdash loads `chart`, `web`, `sqlite` and `crypto`
# from the installed stdlib, and `sudo make install` rewrites those .bas files
# without necessarily moving the interpreter's own mtime -- so stamping only
# the binary would miss the change that is, in practice, the common one.
stamp_platform(){
    local bin lib
    bin="$(stat -c %Y "$GBASIC" 2>/dev/null || echo unknown)"
    lib="$(find "${GDASH_GBASIC_STDLIB:-/usr/local/share/gbasic/stdlib}" -name '*.bas' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
    echo "${bin}:${lib:-none}"
}
GBASIC_STAMP_BEFORE="$(stamp_platform)"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-test-XXXXXX")"
ROOT="$SCRATCH/root"
mkdir -p "$ROOT"

# Snapshot the working tree so the post-run comparison detects residue the
# tests wrote, rather than whatever work happens to be in progress.
TREE_BEFORE="$(cd "$HERE/.." && git status --porcelain 2>/dev/null)"

failed=0
ran=0

for testfile in "$HERE"/test_*.bas; do
    name="$(basename "$testfile" .bas)"
    caseroot="$ROOT/$name"
    mkdir -p "$caseroot"
    ran=$((ran + 1))
    # Handlers cannot see argv (PLAT-WEB), so gdash_app reads its root from the
    # environment (G6-5). An in-process handler test therefore needs it there
    # rather than in args[0]; every other suite ignores it.
    if ! GDASH_ROOT="$caseroot" "$GBASIC" --line-buffered "$testfile" "$caseroot"; then
        failed=$((failed + 1))
    fi
done

# The library-namespace audit. The capture hazard (F6) is fixed in the
# platform as of d08409f; what is left is ambiguity for a caller writing a bare
# name outside every library defining it. library_collisions() reports the
# library-vs-library case, which is now otherwise silent; stderr carries the
# note for a library shadowing a BUILT-IN, which the audit does not cover.
echo "--- library namespace ---"
ran=$((ran + 1))
sweep="$SCRATCH/overrides.err"
if "$GBASIC" "$HERE/overrides_probe.bas" >/dev/null 2>"$sweep" && ! grep -qi "override\|same name as a built-in" "$sweep"; then
    echo "ok   no unaccepted name collisions, library or built-in"
else
    echo "FAIL namespace audit (or the probe would not load):"
    cat "$sweep"
    failed=$((failed + 1))
fi

# The shadowing refusal, in its own processes. Hermetic -- no port, no network
# -- so it runs with the in-process suites rather than behind GDASH_SKIP_E2E.
# It pins the PREMISE first: a stray .bas in gdash's module directory beats the
# installed stdlib. If the platform ever changes that rule, this says the guard
# is now unnecessary rather than leaving it guarding against nothing.
echo "--- shadowing refusal ---"
ran=$((ran + 1))
if ! "$HERE/run_shadow.sh"; then
    failed=$((failed + 1))
fi

# An end-to-end assertion whose needle also appears in the stylesheet or the
# shim passes with the feature removed (G6-6). Eight did.
echo "--- assertion audit ---"
ran=$((ran + 1))
if ! "$HERE/assertion_audit.py"; then
    failed=$((failed + 1))
fi

# The format doc's refusal catalog is generated from the golden. If they
# disagree the documentation is wrong, which is a test failure, not a chore.
echo "--- documentation ---"
ran=$((ran + 1))
if ! "$HERE/../scripts/gen_catalog_appendix.py" --check; then
    failed=$((failed + 1))
fi

# The shared-nothing property under more than one worker. Still hermetic:
# loopback only, fixture source, no database, no display. Skipped with the
# same switch as the end-to-end run, since both want a port.
if [[ "${GDASH_SKIP_E2E:-0}" != "1" ]]; then
    echo "--- multiple workers ---"
    ran=$((ran + 1))
    if ! "$HERE/run_workers.sh"; then
        failed=$((failed + 1))
    fi
fi

# The ODBC origin, through a real driver manager. Opt-in, but the cheapest of
# the live runners: the SQLite driver reads a file, so there is no service.
if [[ "${GDASH_ODBC_TEST:-0}" == "1" ]]; then
    echo "--- ODBC ---"
    ran=$((ran + 1))
    if ! "$HERE/run_odbc.sh"; then
        failed=$((failed + 1))
    fi
fi

# The install, at real FHS paths. Opt-in: it needs root, which means a
# container, which means podman. Named here so `make check` mentions it rather
# than leaving the install untested and unmentioned.
if [[ "${GDASH_FHS_TEST:-0}" == "1" ]]; then
    echo "--- FHS install ---"
    ran=$((ran + 1))
    if ! "$HERE/run_fhs.sh"; then
        failed=$((failed + 1))
    fi
fi

# The concurrency ceiling, at the DEFAULT worker count. For ten phases gdash
# served one fewer viewer than it had workers and the default was one, and no
# suite said so, because every suite that opened a stream opened only as many
# as there were workers to spare.
if [[ "${GDASH_SKIP_E2E:-0}" != "1" ]]; then
    echo "--- concurrency ceiling ---"
    ran=$((ran + 1))
    if ! "$HERE/run_ceiling.sh"; then
        failed=$((failed + 1))
    fi
fi

# Draining. Operations §7 promises a restart finishes the requests it is
# already serving; that was measured once by hand in GDASH-8 and then only
# written down. Slow by construction -- it renders two ~4.5s pages so that
# SIGTERM lands mid-flight -- so it skips with the rest of the port-using
# suites.
if [[ "${GDASH_SKIP_E2E:-0}" != "1" ]]; then
    echo "--- drain ---"
    ran=$((ran + 1))
    if ! "$HERE/run_drain.sh"; then
        failed=$((failed + 1))
    fi
fi

# The races. Three pieces of gdash exist because two things can happen at
# once; until GDASH-6 none of them had ever had two things happen at once.
if [[ "${GDASH_SKIP_E2E:-0}" != "1" ]]; then
    echo "--- concurrency ---"
    ran=$((ran + 1))
    if ! "$HERE/run_races.sh"; then
        failed=$((failed + 1))
    fi
fi

# The end-to-end spine, over a real HTTP server. Still hermetic: loopback
# only, fixture source, no database, no display.
if [[ "${GDASH_SKIP_E2E:-0}" != "1" ]]; then
    echo "--- end-to-end ---"
    ran=$((ran + 1))
    if ! "$HERE/run_e2e.sh"; then
        failed=$((failed + 1))
    fi
fi

GBASIC_STAMP_AFTER="$(stamp_platform)"
if [[ "$GBASIC_STAMP_BEFORE" != "$GBASIC_STAMP_AFTER" ]]; then
    echo
    echo "NOTE: the gbasic platform changed DURING this run." >&2
    echo "      before: $GBASIC_STAMP_BEFORE" >&2
    echo "      after:  $GBASIC_STAMP_AFTER   (interpreter mtime : newest stdlib mtime)" >&2
    echo "      A rebuild or install replaces the binary and the stdlib under a" >&2
    echo "      running suite, and every invocation in that window fails with no" >&2
    echo "      useful output. Any failure above may be an artifact of that," >&2
    echo "      not a gdash defect. Re-run before believing it." >&2
fi

echo "---"
if [[ "$GBASIC_STAMP_BEFORE" != "$GBASIC_STAMP_AFTER" && $failed -gt 0 ]]; then
    echo "suites run: $ran, failed: $failed  -- BUT THE PLATFORM CHANGED MID-RUN; re-run before believing this"
else
    echo "suites run: $ran, failed: $failed"
fi

# Scratch-clean assertion: the suite owns exactly one temp tree and leaves
# nothing outside it. Removing it must succeed and leave no residue.
rm -rf "$SCRATCH"
if [[ -e "$SCRATCH" ]]; then
    echo "SCRATCH NOT CLEAN: $SCRATCH survived removal" >&2
    exit 1
fi
echo "scratch clean: $SCRATCH removed"

# A test run must write nothing into the working tree.
TREE_AFTER="$(cd "$HERE/.." && git status --porcelain 2>/dev/null)"
if [[ "$TREE_BEFORE" != "$TREE_AFTER" ]]; then
    echo "SCRATCH NOT CLEAN: the test run modified the working tree" >&2
    diff <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER") >&2
    exit 1
fi
echo "working tree unchanged by the run"

[[ $failed -eq 0 ]] || exit 1
