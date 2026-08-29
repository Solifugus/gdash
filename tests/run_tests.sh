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
