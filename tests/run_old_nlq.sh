#!/usr/bin/env bash
# gdash against an OLDER nlq than the one installed.
#
# `nlq.plan` gained a `notes` option on 2026-09-14, and that is how gdash tells
# a model that its integers are minor units. An older `nlq` RAISES on an unknown
# option -- correctly; that is what `_options` is for -- so gdash tries with the
# notes and falls back without them once, carrying `units_told` on the draft.
#
# THAT FALLBACK IS OTHERWISE UNREACHABLE now that the platform has the feature,
# and an untested fallback is worse than none: it is the path that runs on the
# day somebody's stdlib and interpreter have drifted apart, which is not a
# hypothetical -- gdash spent a day in exactly that state while the binary
# carried one fix and the stdlib carried neither of the others.
#
# So this builds one: the REAL installed nlq with a single line reverted, placed
# on GBASIC_PATH -- which takes precedence over the installed stdlib and is how
# a deployment actually ends up on an older library. Everything else about it is
# genuine, which is what makes the result mean something.
#
# NOT beside src/. The first version put it there and gdash_shadow refused to
# start, correctly: a library file beside the modules is precisely what that
# guard exists to stop, and it does not care that this one was ours. An older
# library ON THE PATH is a deployment state; one BESIDE THE MODULES is a
# substitution. The guard distinguishing them is asserted below.
#
# Hermetic: no port, no network, no model, no display.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/gsql_owners.sh"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"
STDLIB="${GDASH_GBASIC_STDLIB:-/usr/local/share/gbasic/stdlib}"

pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }

if [[ ! -f "$STDLIB/nlq.bas" ]]; then
    echo "  skip: no installed nlq.bas at $STDLIB" >&2
    exit 0
fi
if ! grep -q '"collapse_siblings", "notes"' "$STDLIB/nlq.bas"; then
    # The installed library predates the option, so the fallback is the only
    # path there is and the rest of the suite already exercises it.
    echo "  skip: the installed nlq has no 'notes' option to take away"
    exit 0
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-oldnlq-XXXXXX")"
SRC="$SCRATCH/src"
ROOT="$SCRATCH/root"
mkdir -p "$ROOT"
cp -r src "$SRC"
unset GDASH_SRC

# The one line that makes it an older library. `plan` no longer accepts the
# option, so it raises exactly as the real older one did.
OLDLIB="$SCRATCH/oldstdlib"
mkdir -p "$OLDLIB"
sed 's/"collapse_siblings", "notes"/"collapse_siblings"/' "$STDLIB/nlq.bas" > "$OLDLIB/nlq.bas"
if ! grep -q '"collapse_siblings" \]' "$OLDLIB/nlq.bas"; then
    echo "  FAIL could not build the older library; the option list has moved" >&2
    wait_for_gsql_owners "$SCRATCH"; rm -rf "$SCRATCH"; exit 1
fi
export GBASIC_PATH="$OLDLIB"

cp tests/model_double.bas "$SCRATCH/"
cat > "$SCRATCH/probe.bas" <<'EOF'
program main(args)
    load model_double from "model_double.bas"
    load gdash_paths from "src/gdash_paths.bas"
    load gdash_store from "src/gdash_store.bas"
    load gdash_ask from "src/gdash_ask.bas"

    root = args[0]
    p = gdash_paths.roles(root)
    rec = { datasets: {} }
    rec["datasets"]["orders"] = { columns: {} }
    rec["datasets"]["orders"]["columns"]["amount"] = { type: "money", scale: 2, currency: "USD" }

    made = gdash_paths.ensure_dir(gdash_paths.data_dir(p, "sales", "draft"))
    rows = [["west", "2026-01", "1250.75"], ["east", "2026-02", "1100.00"]]
    plan = gdash_store.plan_columns(["region", "month", "amount"], rows, { amount: { type: "money", scale: 2 } })
    db = gdash_paths.stage_db(p, "sales", "draft")
    m = gdash_store.materialize(db, "orders", plan, rows)
    msw = gdash_store.swap(db, "orders")

    logp = root + "/prompt.log"
    d = gdash_ask.ask(p, "sales", "draft", rec, "how many orders are there?",
                      model_double.saying_into("select count(*) as n from orders", logp), {})
    print("ok:" + string(d.ok))
    print("stage:" + d.stage)
    print("units_told:" + string(d.units_told))
    print("value:" + string(d.answer.value))
    said = model_double.prompted(logp)
    print("prompted:" + string(len(said) > 0))
    print("mentions_currency_note:" + string(contains(said, "money in USD")))
end program
EOF

out="$(cd "$SCRATCH" && "$GBASIC" probe.bas "$ROOT" 2>"$SCRATCH/err")"
field(){ sed -n "s/^$1://p" <<<"$out"; }

# THE POINT: gdash still answers. A library that cannot be told about units is
# a reason to warn, not a reason to stop working.
ok "gdash still answers against an older nlq" "$(field ok)" "true"
ok "and reaches the answered stage" "$(field stage)" "answered"
ok "and the query still ran" "$(field value)" "2"
ok "the model was still prompted" "$(field prompted)" "true"

# AND IT IS NOT SILENT. A silent fallback would hide exactly the hazard the
# notes exist to close: a confident wrong number about money.
ok "but the draft records that the units were NOT sent" "$(field units_told)" "false"
ok "and the prompt genuinely lacks them" "$(field mentions_currency_note)" "false"

# The CLI says so in words, because a flag nobody prints is a flag nobody sees.
mkdir -p "$ROOT/etc" "$ROOT/lib/dashboards/sales"
cat > "$ROOT/etc/models.json" <<JSON
{ "default": "fixture", "fixture": { "provider": "offline", "model": "f", "offline_dir": "$SCRATCH/model" } }
JSON
mkdir -p "$SCRATCH/model"
cat > "$SCRATCH/model/anthropic_response.json" <<'JSON'
{"id":"m","type":"message","role":"assistant","model":"f","content":[{"type":"text","text":"select count(*) as n from orders"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
JSON
cat > "$ROOT/lib/dashboards/sales/draft.json" <<'JSON'
{"format":1,"name":"sales",
 "datasets":{"orders":{"profile":"fake","sql":"select 1","columns":{"amount":{"type":"money","scale":2,"currency":"USD"}}}},
 "params":{},"visuals":{},"tabs":[{"name":"S","layout":{"vert":[]}}]}
JSON
cli="$("$GBASIC" "$SRC/gdash_cli.bas" --root "$ROOT" ask sales "how many orders are there?" 2>&1)"
if grep -q "too old to be told what the money" <<<"$cli"; then
    echo "  ok   the CLI says the model was not told about the money columns"; pass=$((pass+1))
else
    echo "  FAIL the CLI said nothing about it"; fail=$((fail+1))
fi

# AND THE GUARD DOES NOT FIRE. An older library on the path is a deployment
# state; a library file beside the modules is a substitution. gdash_shadow
# refuses the second and must not refuse the first -- it refused this very
# fixture when the older library was first placed in src/, which is the guard
# being right about a test that was wrong.
if grep -q "refusing to start" <<<"$cli"; then
    echo "  FAIL gdash refused an older library that was merely on the path"; fail=$((fail+1))
else
    echo "  ok   an older library on GBASIC_PATH is not treated as a shadow"; pass=$((pass+1))
fi

wait_for_gsql_owners "$SCRATCH"; rm -rf "$SCRATCH"
if [[ -e "$SCRATCH" ]]; then
    echo "SCRATCH NOT CLEAN: $SCRATCH survived removal" >&2
    exit 1
fi
echo "  old nlq: $pass passed, $fail failed (scratch clean)"
[[ $fail -eq 0 ]]
