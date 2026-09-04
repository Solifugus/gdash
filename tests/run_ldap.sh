#!/usr/bin/env bash
# gdash — live LDAP runner. OPT-IN, never part of the hermetic suite.
#
#   scripts/ldap_test_directory.sh up
#   eval "$(scripts/ldap_test_directory.sh env)"
#   tests/run_ldap.sh
#
# The hermetic suite tests the policy layer -- escaping, DN construction, the
# chain, group normalisation -- and needs no directory. This tests the one
# thing a policy test cannot: that the platform's module and gdash's use of it
# agree with a server neither of them wrote (finding G5-7).

set -uo pipefail

if [[ "${GDASH_LDAP_TEST:-0}" != "1" ]]; then
    echo "skipped: set GDASH_LDAP_TEST=1 to run the live LDAP suite"
    echo "         scripts/ldap_test_directory.sh up && eval \"\$(scripts/ldap_test_directory.sh env)\""
    exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
export GDASH_GBASIC="$GBASIC"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gdash-ldap-XXXXXX")"
ROOT="$SCRATCH/root"
mkdir -p "$ROOT/etc" "$ROOT/lib" "$ROOT/cache" "$ROOT/log" "$ROOT/run"

failed=0
"$GBASIC" --line-buffered "$HERE/ldap_live.bas" "$ROOT" || failed=1

echo "--- the CLI's own diagnosis ---"
# `gdash auth check` is what an operator runs, so the runner runs it the same
# way rather than trusting the library test to stand in for it.
cat > "$ROOT/etc/auth.json" <<JSON
{ "format": 1,
  "directory": { "kind": "ldap", "name": "corp",
                 "host": "${GDASH_LDAP_HOST:-127.0.0.1}", "port": ${GDASH_LDAP_PORT:-3890},
                 "security": "plain",
                 "user_dn_template": "uid={user},ou=people,${GDASH_LDAP_BASE:-dc=example,dc=invalid}",
                 "group_strategy": "search",
                 "group_base": "ou=groups,${GDASH_LDAP_BASE:-dc=example,dc=invalid}",
                 "bind_dn": "${GDASH_LDAP_BIND_DN:-}",
                 "bind_password": "${GDASH_LDAP_BIND_PW:-}" } }
JSON
chmod 600 "$ROOT/etc/auth.json"
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" auth check ada 2>&1)"
rc=$?
if [[ $rc -eq 0 ]] && grep -q "analysts" <<<"$out" && grep -q "finance" <<<"$out"; then
    echo "  ok   auth check resolves both groups"
else
    echo "  FAIL auth check: $out"
    failed=1
fi
if grep -q "${GDASH_LDAP_BIND_PW:-fake-admin-pw}" <<<"$out"; then
    echo "  FAIL auth check printed the service password"
    failed=1
else
    echo "  ok   and prints no password"
fi

# A configuration that is wrong must be refused with a message that says what
# to type, not accepted and left to fail at login.
python3 - "$ROOT/etc/auth.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
del c['directory']['group_strategy']
json.dump(c,open(sys.argv[1],'w'))
PY
out="$("$GBASIC" src/gdash_cli.bas --root "$ROOT" auth check 2>&1)"
if grep -q "group_strategy" <<<"$out" && grep -q "memberof" <<<"$out"; then
    echo "  ok   a profile with no group_strategy is refused, and told what to type"
else
    echo "  FAIL a missing group_strategy was not refused clearly: $out"
    failed=1
fi

echo "--- a directory user signs in over HTTP, and groups gate the dashboard ---"
# Put back the profile the refusal test above deliberately broke.
python3 - "$ROOT/etc/auth.json" <<'FIXCFG'
import json, sys
c = json.load(open(sys.argv[1]))
c['directory']['group_strategy'] = 'search'
json.dump(c, open(sys.argv[1], 'w'))
FIXCFG
# The done-means criterion the library tests cannot reach: an actual browser
# exchange, an actual session, and a dashboard gated on a group that exists
# only in the directory.
python3 - "$ROOT" <<'MKDASH'
import json, os, sys
r = sys.argv[1]
d = json.load(open('dashboards/sales/draft.json'))
d['name'] = 'corp'
d.pop('access', None)
d['view_groups'] = ['analysts']
os.makedirs(f'{r}/lib/dashboards/corp', exist_ok=True)
json.dump(d, open(f'{r}/lib/dashboards/corp/draft.json', 'w'), indent=2)
MKDASH
cat > "$ROOT/etc/connections.json" <<JSON
{ "warehouse":  { "kind": "fixture", "path": "fixtures/orders.json" },
  "regionbook": { "kind": "fixture", "path": "fixtures/regions.json" } }
JSON

PORT=8780
GDASH_ROOT="$ROOT" "$GBASIC" --line-buffered src/gdash_server.bas > "$SCRATCH/server.log" 2>&1 &
SRV=$!
for i in $(seq 1 60); do grep -q "listening" "$SCRATCH/server.log" 2>/dev/null && break; sleep 0.25; done

signin(){ # jar user pass -> prints the login status code
    local jar="$1" user="$2" pass="$3" form tok
    rm -f "$jar"
    form="$(curl -s -c "$jar" --max-time 10 "http://127.0.0.1:$PORT/login")"
    tok="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' <<<"$form")"
    curl -s -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" --max-time 10 \
        -X POST -d "csrf=$tok&user=$user&pass=$pass" "http://127.0.0.1:$PORT/login"
}

code="$(signin "$SCRATCH/ada.txt" ada fake-directory-pw)"
if [[ "$code" == "303" ]]; then echo "  ok   a directory user signs in over HTTP"; else echo "  FAIL directory login: $code"; failed=1; fi

who="$(curl -s -b "$SCRATCH/ada.txt" --max-time 10 "http://127.0.0.1:$PORT/whoami")"
if grep -q '"user":"ada"' <<<"$who" && grep -q 'analysts' <<<"$who"; then
    echo "  ok   carrying the directory's groups into the session"
else
    echo "  FAIL whoami: $who"; failed=1
fi

code="$(curl -s -o /dev/null -w '%{http_code}' -b "$SCRATCH/ada.txt" --max-time 10 "http://127.0.0.1:$PORT/d/corp")"
if [[ "$code" == "200" ]]; then echo "  ok   a dashboard gated on a directory group is served to a member"; else echo "  FAIL member got $code"; failed=1; fi

code="$(signin "$SCRATCH/bo.txt" bo another-fake-pw)"
code="$(curl -s -o /dev/null -w '%{http_code}' -b "$SCRATCH/bo.txt" --max-time 10 "http://127.0.0.1:$PORT/d/corp")"
if [[ "$code" == "403" ]]; then echo "  ok   and refused to a directory user who is not in it"; else echo "  FAIL non-member got $code"; failed=1; fi

if grep -q '"event":"login"' "$ROOT/log/audit.log" && grep -q '"provider":"corp"' "$ROOT/log/audit.log"; then
    echo "  ok   and the audit log names the provider that answered"
else
    echo "  FAIL audit log has no provider-named login"; failed=1
fi
if grep -qF "fake-directory-pw" "$ROOT/log/audit.log"; then
    echo "  FAIL a password reached the audit log"; failed=1
else
    echo "  ok   no password reaches the audit log"
fi

kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null

rm -rf "$SCRATCH"
if [[ -e "$SCRATCH" ]]; then
    echo "SCRATCH NOT CLEAN: $SCRATCH survived removal" >&2
    exit 1
fi
echo "scratch clean: $SCRATCH removed"
exit $failed
