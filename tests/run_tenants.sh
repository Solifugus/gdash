#!/usr/bin/env bash
# gdash — two tenants, one server, and the wall between them (GDASH-15).
#
# gdash_saas_design.md: a tenant is a root, the wall is the filesystem, and
# resolution happens once, from the Host header, with an unknown host refused.
# Each of those is asserted here, on every run, because isolation that is not
# executed on every run is isolation nobody can vouch for a year from now.
#
# Loopback only, fixture sources, no database, no display. Port 8787.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/gsql_owners.sh"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"
PORT=8787

PREEXISTING=" $(pgrep -f "gdash_server.bas" 2>/dev/null | tr '\n' ' ') "
reap(){
    local pid
    for pid in $(pgrep -f "gdash_server.bas" 2>/dev/null); do
        [[ "$(cat /proc/$pid/comm 2>/dev/null)" == "gbasic" ]] || continue
        [[ "$PREEXISTING" == *" $pid "* ]] && continue
        kill "$pid" 2>/dev/null
    done
}
trap reap EXIT
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT\$"; then
    echo "port $PORT is already in use; this suite will not kill a stranger" >&2; exit 2
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-tenants-XXXXXX")"
BASE="$SCRATCH/base"          # the server's own root: holds the registry
TROOTS="$SCRATCH/tenants"     # where tenant roots live
mkdir -p "$BASE/etc" "$BASE/lib" "$BASE/cache" "$BASE/log" "$BASE/run"
pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }
has(){ if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3: <$2> not found"; fail=$((fail+1)); fi; }
hasnt(){ if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3: <$2> should be absent"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }
CLI(){ "$GBASIC" src/gdash_cli.bas --root "$BASE" "$@"; }

echo "--- creating tenants ---"
out="$(CLI tenant create acme --host acme.example.test --base "$TROOTS" 2>&1)"
has "$out" "created tenant acme" "a tenant is created"
ok "under the base, at a root derived from its id" "$(test -d "$TROOTS/acme/etc" && echo yes)" "yes"
ok "with a format stamp" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['format'])" "$TROOTS/acme/etc/tenant.json")" "1"
out="$(CLI tenant create globex --host globex.example.test --host bi.globex.test 2>&1)"
has "$out" "created tenant globex" "a second tenant joins the registry"
for bad in ".." "../x" "ACME" "a.b" "-x" "x-" "a/b"; do
    out="$(CLI tenant create "$bad" --host x.example.test 2>&1)"; rc=$?
    ok "tenant id '$bad' is refused" "$rc" "1"
done
out="$(CLI tenant create initech --host ACME.example.test 2>&1)"; rc=$?
ok "a host another tenant already has is refused, whatever its case" "$rc" "1"
has "$(CLI tenant list 2>&1)" "globex  active  globex.example.test,bi.globex.test" "the registry lists both"
ok "and nothing half-created was registered" "$(python3 -c "import json,sys;print(sorted(json.load(open(sys.argv[1]))['tenants']))" "$BASE/etc/tenants.json")" "['acme', 'globex']"

echo "--- two tenants, the same dashboard name, different data ---"
for t in acme globex; do
    fx="fixtures/orders.json"; [[ "$t" == "globex" ]] && fx="fixtures/orders_moved.json"
    mkdir -p "$TROOTS/$t/lib/dashboards/sales"
    cat > "$TROOTS/$t/etc/connections.json" <<JSON
{ "warehouse": { "kind": "fixture", "path": "$fx" } }
JSON
    python3 - "$TROOTS/$t" "$t" <<'PYEOF'
import json,sys
root,t=sys.argv[1],sys.argv[2]
rec={"format":1,"name":"sales","title":"Sales of "+t,"access":"open",
 "datasets":{"orders":{"profile":"warehouse","sql":"select region, month, amount from orders","columns":{"amount":{"type":"money","scale":2}}}},
 "params":{},"visuals":{"n":{"dataset":"orders","sql":"select count(*) as n from orders","encoding":{"mark":"value","value":"n","title":"Rows"}}},
 "tabs":[{"name":"S","layout":{"vert":[{"visual":"n"}]}}]}
json.dump(rec,open(root+"/lib/dashboards/sales/draft.json","w"))
PYEOF
    CLI --tenant "$t" refresh sales --draft >/dev/null 2>&1
done
mkdir -p "$TROOTS/acme/lib/dashboards/private"
cp "$TROOTS/acme/lib/dashboards/sales/draft.json" "$TROOTS/acme/lib/dashboards/private/draft.json"
sed -i 's/"name": *"sales"/"name":"private"/' "$TROOTS/acme/lib/dashboards/private/draft.json"
CLI --tenant acme refresh private --draft >/dev/null 2>&1
ok "--tenant puts a dashboard's data in that tenant's root" "$(test -d "$TROOTS/acme/cache/sales/draft/data.gsql" && echo yes)" "yes"
ok "and nothing in the server's own root" "$(ls "$BASE/cache" | wc -l)" "0"
printf 'fake-acme-pw\nfake-acme-pw\n' | CLI --tenant acme user add alice --admin >/dev/null 2>&1

echo "--- one server, routed by Host ---"
GDASH_ROOT="$BASE" GDASH_PORT="$PORT" "$GBASIC" --line-buffered src/gdash_server.bas > "$SCRATCH/server.log" 2>&1 &
for i in $(seq 1 60); do grep -q "listening" "$SCRATCH/server.log" 2>/dev/null && break; sleep 0.25; done
get(){ curl -s --max-time 10 -H "Host: $1" "http://127.0.0.1:$PORT$2"; }
code(){ curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $1" "http://127.0.0.1:$PORT$2"; }
# --- access: open is the operator's to grant in a tenant (GDASH-16) ---
# Both records say `access: open`. Until the operator permits it, a tenant's
# open record serves nobody anonymous, and publishing one is refused.
ok "a tenant's open record is NOT open until the operator grants it" "$(code acme.example.test /d/sales)" "404"
out="$(CLI --tenant acme publish sales 2>&1)"; rc=$?
ok "and publishing one is refused" "$rc" "1"
has "$out" "may not publish a dashboard with access: open" "saying why, and what to do instead"
has "$(CLI tenant limits acme 2>&1)" "open_access  false" "tenant limits shows the gate closed by default"
CLI tenant limit acme open_access true >/dev/null 2>&1
CLI tenant limit globex open_access true >/dev/null 2>&1
has "$(CLI tenant limits acme 2>&1)" "open_access  true" "and open once granted"
out="$(CLI tenant limit acme open_access yes 2>&1)"; rc=$?
ok "a limit that is not its kind is refused" "$rc" "1"

a="$(get acme.example.test /d/sales)"; g="$(get globex.example.test /d/sales)"
has "$a" "Sales of acme" "acme's host serves acme's dashboard"
has "$g" "Sales of globex" "globex's host serves globex's dashboard of the same name"
has "$a" ">6<" "with acme's data (6 rows)"
has "$g" ">7<" "and globex's (7 rows), not acme's"
has "$(get bi.globex.test /d/sales)" "Sales of globex" "a tenant's second host is the same tenant"
has "$(get GLOBEX.example.test:$PORT /d/sales)" "Sales of globex" "a host is matched without its case or its port"
ok "a dashboard only acme has is a 404 at globex" "$(code globex.example.test /d/private)" "404"
ok "and is there at acme" "$(code acme.example.test /d/private)" "200"
ok "an unknown host is refused, not served a default tenant" "$(code nobody.example.test /d/sales)" "404"
has "$(get nobody.example.test /)" "no such site" "saying so, and nothing else"
ok "nor is the server's own root served to an unknown host" "$(code 127.0.0.1 /)" "404"
# What matters is that no spelling of a path leaves the tenant: none of these
# may show acme's dashboard at globex's host. (`/d/%2e%2e` normalises to `/`,
# which is globex's own index -- inside globex, and correct.)
for bad in "/d/..%2Facme" "/d/../acme" "/d/%2e%2e" "/d/..%2F..%2Ftenants%2Facme%2Flib%2Fdashboards%2Fprivate" "/d/private%00"; do
    hasnt "$(get globex.example.test "$bad")" "Sales of acme" "'$bad' at globex reaches nothing of acme's"
done

echo "--- a session belongs to the tenant that issued it ---"
jar="$SCRATCH/acme.jar"
form="$(curl -s -c "$jar" -H "Host: acme.example.test" --max-time 10 "http://127.0.0.1:$PORT/login")"
tok="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' <<<"$form")"
curl -s -o /dev/null -b "$jar" -c "$jar" -H "Host: acme.example.test" --max-time 10 -X POST -d "csrf=$tok&user=alice&pass=fake-acme-pw" "http://127.0.0.1:$PORT/login"
has "$(curl -s -b "$jar" -H "Host: acme.example.test" --max-time 10 "http://127.0.0.1:$PORT/whoami")" '"user":"alice"' "alice is signed in at acme"
sid="$(awk '$6=="gdash_session"{print $7}' "$jar" | tail -1)"
has "$(curl -s -H "Host: globex.example.test" -H "Cookie: gdash_session=$sid" --max-time 10 "http://127.0.0.1:$PORT/whoami")" '"authenticated":false' "the same session id presented to globex is anonymous"
hasnt "$(curl -s -D - -o /dev/null -H "Host: acme.example.test" --max-time 10 "http://127.0.0.1:$PORT/login")" "Domain=" "the session cookie names no Domain, so subdomain tenants never share it"

echo "--- one tenant's queries cannot reach another's data ---"
# acme's private dashboard has a dataset `orders`; globex has its own. A
# globex visual naming a table only acme has finds nothing: each tenant's
# dashboards are separate databases under separate roots.
python3 - "$TROOTS/globex" <<'PYEOF'
import json,sys
p=sys.argv[1]+"/lib/dashboards/sales/draft.json"
d=json.load(open(p))
d["visuals"]["reach"]={"dataset":"orders","sql":"select count(*) as n from private","encoding":{"mark":"value","value":"n"}}
d["tabs"][0]["layout"]["vert"].append({"visual":"reach"})
json.dump(d,open(p,"w"))
PYEOF
has "$(get globex.example.test /d/sales)" "query failed" "a globex query naming acme's data finds no such table"

echo "--- suspension, and a registry that does not read ---"
CLI tenant suspend globex >/dev/null 2>&1
ok "a suspended tenant is refused at resolution" "$(code globex.example.test /d/sales)" "403"
ok "and only that tenant" "$(code acme.example.test /d/sales)" "200"
# globex's record now holds the cross-tenant visual above, which the channel
# check (GDASH-21) refuses at validate time -- so reaching it at all is what
# shows the operator acted on the suspended tenant's own record.
has "$(CLI --tenant globex validate sales 2>&1)" "visual 'reach'" "an operator can still act on a suspended tenant, and validate catches the cross-tenant query"
CLI tenant resume globex >/dev/null 2>&1
ok "resumed, it serves again" "$(code globex.example.test /d/sales)" "200"
cp "$BASE/etc/tenants.json" "$SCRATCH/tenants.good"
printf '{ "format": 1, "base": "%s", "tenants": { "acme": { "hosts": ["acme.example.test"], "status": "maybe" } } }' "$TROOTS" > "$BASE/etc/tenants.json"
ok "an invalid registry refuses every host rather than guess" "$(code acme.example.test /d/sales)" "503"
cp "$SCRATCH/tenants.good" "$BASE/etc/tenants.json"
ok "and the restored one serves again" "$(code acme.example.test /d/sales)" "200"

echo "--- deleting a tenant makes it unreachable and keeps its data ---"
out="$(CLI tenant delete globex 2>&1)"
has "$out" "unreachable" "delete says what it did"
ok "its hosts are refused at once" "$(code globex.example.test /d/sales)" "404"
ok "and its directory is still there" "$(test -d "$TROOTS/globex/lib/dashboards/sales" && echo yes)" "yes"

reap
wait_for_gsql_owners "$SCRATCH"; rm -rf "$SCRATCH"
[[ -e "$SCRATCH" ]] && { echo "SCRATCH NOT CLEAN: $SCRATCH" >&2; exit 1; }
echo "---"
echo "tenants: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
