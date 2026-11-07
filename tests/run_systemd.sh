#!/usr/bin/env bash
# gdash under systemd — the units, actually started.
#
# For eight phases `systemd-analyze verify` accepted every directive and no
# `systemctl start` ever happened; operations §10 said so in as many words, and
# gave the reason as "there is no systemd in the container used for testing".
# THAT REASON WAS WRONG: rootless podman boots systemd as PID 1 given
# --systemd=always and --cap-add=all, which is what this runner does. Verify
# checks that a unit PARSES. Only starting one checks that ProtectSystem,
# CapabilityBoundingSet, User= and StateDirectory= let gdash do its job.
#
# Full fidelity: real systemd, real root, real FHS paths, the real units as the
# Makefile installs them, and the real hardening. The host's /usr is mounted
# read-only so the interpreter's shared libraries resolve, exactly as
# run_fhs.sh does.
#
# Opt-in: it needs podman and a few minutes.

set -uo pipefail
if [[ "${GDASH_SYSTEMD_TEST:-0}" != "1" ]]; then
    echo "skipped: set GDASH_SYSTEMD_TEST=1 to run the systemd suite (needs podman)"
    exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
IMAGE="${GDASH_SYSTEMD_IMAGE:-docker.io/library/ubuntu:26.04}"
CT="gdash-systemd-test-$$"

command -v podman >/dev/null 2>&1 || { echo "podman is not installed" >&2; exit 2; }
[[ -x "$GBASIC" ]] || { echo "gbasic not found at $GBASIC" >&2; exit 2; }

pass=0; fail=0
ok(){ if [[ "$2" == "$3" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected <$3> got <$2>"; fail=$((fail+1)); fi; }
yes_(){ if [[ -n "$2" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
no_(){ if [[ -z "$2" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: unexpected <$2>"; fail=$((fail+1)); fi; }
inct(){ podman exec "$CT" "$@"; }
sh_ct(){ podman exec "$CT" /bin/sh -c "$1"; }
# SCOPING A JOURNAL READ TO ONE RUN. `--since '-30s'` also catches the previous
# invocation, and a needle from a SUCCESSFUL earlier run made a failing pass
# look fine. _SYSTEMD_INVOCATION_ID looked like the precise tool and is not:
# it comes back empty for a oneshot that has already exited. A cursor taken
# before the start is reliable for both outcomes.
cursor_now(){ inct sh -c "journalctl --no-pager -n 0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p'"; }
since_cursor(){ inct journalctl --no-pager --after-cursor "$1" -u "$2" 2>/dev/null; }

cleanup(){ podman rm -f "$CT" >/dev/null 2>&1; }
trap cleanup EXIT

echo "--- booting systemd as PID 1 ---"
podman run -d --name "$CT" --systemd=always --cap-add=all \
    -v /usr:/usr:ro -v /lib:/lib:ro -v /lib64:/lib64:ro \
    -v "$GBASIC:/gbasic:ro" -v "$PWD:/src:ro" \
    --tmpfs /usr/local --tmpfs /run --tmpfs /tmp \
    "$IMAGE" /usr/lib/systemd/systemd --unit=multi-user.target >/dev/null 2>&1 || {
        echo "  FAIL could not start the container" >&2; exit 1; }

for _ in $(seq 1 30); do
    [[ "$(inct systemctl is-system-running 2>/dev/null)" =~ running|degraded ]] && break
    sleep 1
done
state="$(inct systemctl is-system-running 2>/dev/null)"
yes_ "systemd is up as PID 1 (state: ${state:-none})" "$state"

echo "--- install, at real FHS paths, and the account the install tells you to make ---"
sh_ct 'cd /src && make install PREFIX=/usr/local UNITDIR=/etc/systemd/system' >/dev/null 2>&1
ok "make install exits 0" "$?" "0"
# @BINDIR@ substitution is what turns a verifiable unit into a startable one.
no_ "no unsubstituted @PLACEHOLDER@ survives in the units" \
    "$(sh_ct 'grep -h "@[A-Z]*@" /etc/systemd/system/gdash*.service /etc/systemd/system/gdash*.timer 2>/dev/null' || true)"
ok "systemd-analyze verify still passes on the installed units" \
   "$(sh_ct 'systemd-analyze verify /etc/systemd/system/gdash.service /etc/systemd/system/gdash-scheduler.service >/dev/null 2>&1; echo $?')" "0"

sh_ct 'useradd --system --no-create-home gdash
cat > /etc/gdash/environment <<EOF
GDASH_GBASIC=/gbasic
GDASH_WORKERS=2
EOF
mkdir -p /var/lib/gdash/dashboards/sales /var/lib/gdash/fixtures
cp /src/dashboards/sales/draft.json /var/lib/gdash/dashboards/sales/draft.json
cp /src/fixtures/*.json /var/lib/gdash/fixtures/
cat > /etc/gdash/connections.json <<JSON
{ "warehouse":  { "kind": "fixture", "path": "/var/lib/gdash/fixtures/orders.json" },
  "regionbook": { "kind": "fixture", "path": "/var/lib/gdash/fixtures/regions.json" } }
JSON
chown -R gdash:gdash /var/lib/gdash /etc/gdash' >/dev/null 2>&1

echo "--- systemctl enable --now gdash ---"
inct systemctl enable --now gdash >/dev/null 2>&1
sleep 3
ok "the service is active" "$(inct systemctl is-active gdash)" "active"
ok "and enabled at boot" "$(inct systemctl is-enabled gdash)" "enabled"
ok "it did not need a restart to get there" "$(inct systemctl show gdash -p NRestarts --value)" "0"

# StateDirectory= and friends are why this unit needs no ReadWritePaths under
# ProtectSystem=strict. Whether they actually produced writable directories
# owned by the service user is a thing only a start can answer.
for d in /var/lib/gdash /var/cache/gdash /var/log/gdash /run/gdash; do
    ok "systemd created $d as gdash:gdash" "$(sh_ct "stat -c %U:%G $d 2>/dev/null")" "gdash:gdash"
done
ok "it runs as the service account, not root" "$(sh_ct 'ps -o user= -p $(systemctl show gdash -p MainPID --value) | tr -d " "')" "gdash"

sh_ct 'command -v curl >/dev/null || apt-get install -y -qq curl' >/dev/null 2>&1
ok "it serves" "$(sh_ct 'curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8780/')" "200"
ok "and renders a dashboard" "$(sh_ct 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8780/d/sales')" "200"

echo "--- the hardening lets gdash spawn its refresh child ---"
# ProtectSystem=strict, NoNewPrivileges, CapabilityBoundingSet= empty,
# RestrictNamespaces -- a refresh forks an interpreter, and whether that
# survives the sandbox is the question verify cannot ask.
sh_ct 'python3 - <<PY
import json, os
d = json.load(open("/var/lib/gdash/dashboards/sales/draft.json"))
d["name"] = "timed"
for ds in d["datasets"].values():
    ds["refresh"] = "interval"; ds["every"] = 1
os.makedirs("/var/lib/gdash/dashboards/timed", exist_ok=True)
json.dump(d, open("/var/lib/gdash/dashboards/timed/draft.json", "w"), indent=2)
PY
chown -R gdash:gdash /var/lib/gdash
runuser -u gdash -- env GDASH_GBASIC=/gbasic /usr/local/bin/gdash refresh timed >/dev/null 2>&1
runuser -u gdash -- env GDASH_GBASIC=/gbasic /usr/local/bin/gdash publish timed >/dev/null 2>&1' >/dev/null 2>&1
cur="$(cursor_now)"
inct systemctl start gdash-scheduler.service >/dev/null 2>&1
ok "the scheduler oneshot succeeds under full hardening" "$(inct systemctl show gdash-scheduler -p Result --value)" "success"
schedlog="$(since_cursor "$cur" gdash-scheduler)"
# EITHER OUTCOME PROVES THE CHILD RAN. A refresh always spawns an interpreter
# and fetches; the content hash then decides whether the swap happens, so
# identical data reports "unchanged" (G2-10) and that is still a child that
# started, fetched and wrote a staging file under the sandbox.
yes_ "and a dataset was actually processed by a spawned child" \
     "$(grep -oE 'timed\.(orders|regions): (refreshed [0-9]+ rows|unchanged)' <<<"$schedlog" | head -1)"
yes_ "with nothing failing under the sandbox" \
     "$(grep -oE 'schedule: [0-9]+ checked, [0-9]+ refreshed, [0-9]+ unchanged, 0 failed' <<<"$schedlog" | head -1)"

echo "--- A1: a refresh while a viewer has the dashboard open ---"
# THE CASE GDASH-20 S0-6 PREDICTED, MEASURED. A viewer's page makes a server
# worker start the G-SQL owner of timed/published (linger 30 s). The scheduler
# then refreshes the same database from ANOTHER unit, and PrivateTmp gives each
# unit its own /tmp -- where the owner's socket lives when XDG_RUNTIME_DIR is
# unset. So the scheduler cannot find the server's owner.
#
# This is a probe of a KNOWN LIMIT (gdash20_platform_ask_gsql.md A1), not a
# pass: it is green while the limit holds, and goes red, saying so, when the
# platform fixes it -- at which point it becomes a plain assertion that the
# refresh is prompt.
touch_db="$(sh_ct 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8780/d/timed')"
ok "a viewer opens the published dashboard, so its owner is running" "$touch_db" "200"
sh_ct 'sleep 1.5' >/dev/null 2>&1
cur="$(cursor_now)"
a1t0=$(date +%s%N)
inct systemctl start gdash-scheduler.service >/dev/null 2>&1
a1ms=$(( ($(date +%s%N) - a1t0) / 1000000 ))
echo "  measured: the scheduler pass took ${a1ms}ms (the server owner's linger is 30 s)"
a1log="$(since_cursor "$cur" gdash-scheduler)"
a1line="$(grep -oE 'schedule: [0-9]+ checked, [0-9]+ refreshed, [0-9]+ unchanged, [0-9]+ failed' <<<"$a1log" | head -1)"
echo "  measured: ${a1line:-no schedule line}"
# MEASURED SHAPE (2026-11-06, build db72b76): not a failure but a STALL. The
# scheduler's client cannot see the server's owner, loses the lock race,
# retries -- and gets through only once the server's owner lingers out: 28.5 s
# against a 30 s linger begun 1.5 s earlier. Under steady viewing every request
# renews that linger, so the stall lasts as long as people are looking.
if grep -qE ', [1-9][0-9]* failed' <<<"$a1line" || (( a1ms > 10000 )); then
    echo "  ok   KNOWN LIMIT A1 holds: a refresh stalls or fails while the server holds the database open"; pass=$((pass+1))
else
    echo "  FAIL A1 no longer reproduces (${a1ms}ms, no failure) -- if the platform fixed it, make this a plain assertion that the refresh is prompt"; fail=$((fail+1))
fi

echo "--- G14-1: a directory the service user cannot write into ---"
# The install message tells an administrator to run the CLI before the service
# exists. That leaves <cache>/<dashboard>/ owned by root inside a <cache> owned
# by the service user, and the first refresh the SERVICE performs cannot create
# published/ in it. It used to raise at a lock-file write and kill the pass.
sh_ct 'rm -rf /var/cache/gdash/timed && mkdir -p /var/cache/gdash/timed/draft && chown root:root /var/cache/gdash/timed' >/dev/null 2>&1
cur="$(cursor_now)"
inct systemctl start gdash-scheduler.service >/dev/null 2>&1
jrnl="$(since_cursor "$cur" gdash-scheduler)"
yes_ "the failing invocation logged something at all" "$jrnl"
no_ "it does not die with a runtime error" "$(grep -o 'runtime error' <<<"$jrnl" | head -1)"
yes_ "it names the directory it cannot create" "$(grep -o 'cannot create the data directory[^"]*' <<<"$jrnl" | head -1)"
yes_ "and tells the operator what to check" "$(grep -o 'service user owns it' <<<"$jrnl" | head -1)"
yes_ "the pass still reports a total rather than stopping" "$(grep -o 'schedule: [0-9]* checked[^"]*' <<<"$jrnl" | tail -1)"
sh_ct 'chown -R gdash:gdash /var/cache/gdash' >/dev/null 2>&1

echo "--- restart, and the drain promise (operations §7) ---"
before="$(inct systemctl show gdash -p MainPID --value)"
inct systemctl restart gdash >/dev/null 2>&1
sleep 3
after="$(inct systemctl show gdash -p MainPID --value)"
ok "restart leaves it active" "$(inct systemctl is-active gdash)" "active"
yes_ "with a new main process" "$([[ "$before" != "$after" ]] && echo yes)"
ok "and it serves again afterwards" "$(sh_ct 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8780/d/sales')" "200"
ok "a restart is not counted as a failure" "$(inct systemctl show gdash -p NRestarts --value)" "0"

echo "--- Restart=on-failure actually restarts ---"
pid="$(inct systemctl show gdash -p MainPID --value)"
sh_ct "kill -9 $pid" >/dev/null 2>&1
for _ in $(seq 1 20); do
    [[ "$(inct systemctl is-active gdash 2>/dev/null)" == "active" ]] && \
      [[ "$(inct systemctl show gdash -p MainPID --value)" != "$pid" ]] && break
    sleep 1
done
ok "a killed supervisor comes back" "$(inct systemctl is-active gdash)" "active"
yes_ "and systemd counted the restart" "$(inct systemctl show gdash -p NRestarts --value | grep -v '^0$')"
ok "the replacement serves" "$(sh_ct 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8780/')" "200"

echo "--- the timer ---"
inct systemctl enable --now gdash-scheduler.timer >/dev/null 2>&1
ok "the timer is active" "$(inct systemctl is-active gdash-scheduler.timer)" "active"
yes_ "and systemd lists when it next runs" "$(inct systemctl list-timers gdash-scheduler.timer --no-pager 2>/dev/null | grep -o 'gdash-scheduler.timer')"

echo "--- stop, and what a stop takes with it ---"
inct systemctl stop gdash >/dev/null 2>&1
ok "the service stops cleanly" "$(inct systemctl is-active gdash)" "inactive"
ok "and stopping is not a failure" "$(inct systemctl show gdash -p Result --value)" "success"
# /run/gdash holds sessions. gdash.service declares RuntimeDirectory= without
# RuntimeDirectoryPreserve=, so a stop removes it -- which is the documented
# behaviour (a reboot signs everyone out) and worth pinning rather than
# assuming.
ok "the dashboards survive the stop" "$(sh_ct 'test -f /var/lib/gdash/dashboards/sales/draft.json && echo yes')" "yes"
ok "the staged cache survives the stop" "$(sh_ct 'test -d /var/cache/gdash && echo yes')" "yes"

echo "--- uninstall leaves the data alone ---"
sh_ct 'cd /src && make uninstall PREFIX=/usr/local UNITDIR=/etc/systemd/system' >/dev/null 2>&1
ok "the units are gone" "$(sh_ct 'ls /etc/systemd/system/gdash.service 2>/dev/null | wc -l')" "0"
ok "the dashboards are not" "$(sh_ct 'test -f /var/lib/gdash/dashboards/sales/draft.json && echo yes')" "yes"

echo "  systemd: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
