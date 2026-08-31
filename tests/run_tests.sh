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
    if ! "$GBASIC" --line-buffered "$testfile" "$caseroot"; then
        failed=$((failed + 1))
    fi
done

# The library-namespace audit. gBASIC function names are global and a second
# definition silently wins (F6). Two checks, because neither covers the other:
# library_collisions() reports the latent library-vs-library state, and stderr
# carries the call-triggered warning for a library shadowing a BUILT-IN.
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

# The format doc's refusal catalog is generated from the golden. If they
# disagree the documentation is wrong, which is a test failure, not a chore.
echo "--- documentation ---"
ran=$((ran + 1))
if ! "$HERE/../scripts/gen_catalog_appendix.py" --check; then
    failed=$((failed + 1))
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

echo "---"
echo "suites run: $ran, failed: $failed"

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
