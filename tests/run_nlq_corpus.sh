#!/usr/bin/env bash
# The corpus numbers `nlq_for_gdash.md` asks for.
#
# Hermetic by default: the grounding tier needs no model, because `nlq.plan`
# does no I/O. It stages the reference dashboard from the fixture source and
# grounds twenty questions against it -- fifteen the catalog should settle and
# five it should refuse.
#
# GDASH_NLQ_TEST=1 adds the answer tier, which needs a real model configured in
# the root's models.json. That one is not in the suite: it costs money, it needs
# the network, and its result is a distribution rather than a pass.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/gsql_owners.sh"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"
export GDASH_SRC="$HERE/../src"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-corpus-XXXXXX")"
ROOT="$SCRATCH/root"
mkdir -p "$ROOT/lib/dashboards/sales" "$ROOT/etc" "$ROOT/cache" "$ROOT/log" "$ROOT/run"
cp dashboards/sales/draft.json "$ROOT/lib/dashboards/sales/draft.json"

# Obviously-fake values; the fixture source needs no credentials.
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse":  { "kind": "fixture", "path": "fixtures/orders.json" },
  "regionbook": { "kind": "fixture", "path": "fixtures/regions.json" } }
JSON

# A models.json supplied from outside is what the answer tier runs against.
if [[ -n "${GDASH_MODELS_FILE:-}" && -f "${GDASH_MODELS_FILE}" ]]; then
    cp "$GDASH_MODELS_FILE" "$ROOT/etc/models.json"
fi

"$GBASIC" src/gdash_cli.bas --root "$ROOT" refresh sales >/dev/null 2>&1 || {
    echo "could not stage the reference dashboard" >&2
    wait_for_gsql_owners "$SCRATCH"; rm -rf "$SCRATCH"
    exit 2
}

"$GBASIC" tests/nlq_corpus.bas "$ROOT" sales
rc=$?

wait_for_gsql_owners "$SCRATCH"; rm -rf "$SCRATCH"
if [[ -e "$SCRATCH" ]]; then
    echo "SCRATCH NOT CLEAN: $SCRATCH survived removal" >&2
    exit 1
fi
echo "  scratch clean"
exit $rc
