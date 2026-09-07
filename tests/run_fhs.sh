#!/usr/bin/env bash
# gdash — the install, at real FHS paths.
#
#   GDASH_FHS_TEST=1 tests/run_fhs.sh
#
# Opt-in like the Postgres and LDAP runners, and for the same reason: it needs
# something the hermetic suite cannot have. Here that is ROOT, to write
# /etc/gdash and /var/lib/gdash.
#
# This account has neither sudo nor user namespaces, but rootless podman works.
# The container mounts the HOST'S /usr, /lib and /lib64 read-only -- the real
# interpreter with its fifty shared libraries -- over a base image that
# supplies only an empty /etc, /var and /run. /usr/local is a tmpfs on top,
# because it lives INSIDE the read-only /usr and an install needs somewhere to
# land. That combination is exactly the
# install target, and nothing here is a simulation of it.
#
# Why it exists: FHS mode had never executed before GDASH-8 (G8-1), and the
# first thing it found was that gdash could only refresh when started from its
# own repository (G8-2). Without this runner, the third such assumption hides
# the same way -- everything works from the repo root until it does not.

set -uo pipefail

if [[ "${GDASH_FHS_TEST:-0}" != "1" ]]; then
    echo "skipped: set GDASH_FHS_TEST=1 to run the FHS install suite (needs podman)"
    exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
GBASIC="${GDASH_GBASIC:-$HOME/development/gbasic/gbasic}"
IMAGE="${GDASH_FHS_IMAGE:-docker.io/library/ubuntu:24.04}"

command -v podman >/dev/null 2>&1 || { echo "podman is not installed" >&2; exit 2; }
[[ -x "$GBASIC" ]] || { echo "gbasic not found at $GBASIC" >&2; exit 2; }

# The whole suite runs inside the container; results come back on stdout and
# are asserted here, so a failure names itself rather than an exit code.
out="$(timeout 300 podman run --rm \
    -v /usr:/usr:ro -v /lib:/lib:ro -v /lib64:/lib64:ro \
    --tmpfs /usr/local \
    -v "$GBASIC:/gbasic:ro" \
    -v "$PWD:/src:ro" \
    -w /src \
    "$IMAGE" /bin/sh -c '
      set -u
      # A real install, staged nowhere: straight into the container root.
      make install PREFIX=/usr/local UNITDIR=/etc/systemd/system >/dev/null 2>&1 \
        || { echo "MARK install-failed"; exit 1; }
      echo "MARK installed"
      [ -x /usr/local/bin/gdash ] && echo "MARK wrapper-executable"
      [ -f /usr/local/lib/gdash/gdash_refresh_child.bas ] && echo "MARK child-installed"

      # Everything from here uses the INSTALLED gdash, from a working directory
      # that is not the source tree, with no GDASH_SRC and no GDASH_ROOT. Only
      # GDASH_GBASIC, because the interpreter is bind-mounted at an unusual
      # path in this container rather than installed on PATH.
      export GDASH_GBASIC=/gbasic
      mkdir -p /var/lib/gdash/dashboards/sales /var/lib/gdash/fixtures
      cp /src/dashboards/sales/draft.json /var/lib/gdash/dashboards/sales/draft.json
      cp /src/fixtures/*.json /var/lib/gdash/fixtures/
      cat > /etc/gdash/connections.json <<JSON
{ "warehouse":  { "kind": "fixture", "path": "/var/lib/gdash/fixtures/orders.json" },
  "regionbook": { "kind": "fixture", "path": "/var/lib/gdash/fixtures/regions.json" } }
JSON
      cd /

      gdash validate sales 2>&1 | grep -q "validates" && echo "MARK validate"
      gdash refresh sales   2>&1 | grep -q "version"   && echo "MARK refresh"
      [ -f /var/cache/gdash/sales/draft/orders.db ] && echo "MARK staged-in-cache"
      gdash publish sales   2>&1 | grep -q "published" && echo "MARK publish"
      [ -f /var/lib/gdash/dashboards/sales/snapshots/0001.json ] && echo "MARK snapshot-in-state"
      gdash user add ada --groups analysts <<PW >/dev/null 2>&1
fake-fhs-pw
fake-fhs-pw
PW
      [ -f /etc/gdash/users.json ] && echo "MARK users-in-etc"
      [ "$(stat -c %a /etc/gdash/users.json)" = "600" ] && echo "MARK users-restricted"

      # The server, at FHS paths, answering a request.
      gdash-server >/tmp/srv.log 2>&1 &
      for i in $(seq 1 60); do
          grep -qE "listening|^PORT " /tmp/srv.log 2>/dev/null && break
          sleep 0.25
      done
      for i in $(seq 1 60); do
          code=$(( $(command -v curl >/dev/null 2>&1 && curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8780/ 2>/dev/null || echo 0) ))
          [ "$code" = "200" ] && break
          sleep 0.25
      done
      if command -v curl >/dev/null 2>&1; then
          [ "$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8780/d/sales)" = "200" ] && echo "MARK served"
      else
          echo "MARK no-curl"
      fi

      # And it comes back off cleanly.
      # -C /src because everything above deliberately ran from /, which is the
      # point of the suite -- and which also moves `make`.
      make -C /src uninstall PREFIX=/usr/local UNITDIR=/etc/systemd/system >/dev/null 2>&1
      [ ! -e /usr/local/bin/gdash ] && echo "MARK uninstalled"
      [ -d /var/lib/gdash/dashboards/sales ] && echo "MARK data-survived-uninstall"
      [ -f /etc/gdash/users.json ] && echo "MARK config-survived-uninstall"
    ' 2>&1)"

pass=0; fail=0
want(){ if grep -q "MARK $1" <<<"$out"; then echo "  ok   $2"; pass=$((pass+1)); else echo "  FAIL $2"; fail=$((fail+1)); fi; }

echo "--- a real install at real paths ---"
want installed                 "make install succeeds as root, into the FHS layout"
want wrapper-executable        "the operator's \`gdash\` command is installed and executable"
want child-installed           "and the refresh child ships beside the library it belongs to"
echo "--- and gdash runs there, with no GDASH_ROOT and no GDASH_SRC ---"
want validate                  "validate finds a dashboard under /var/lib/gdash"
want refresh                   "refresh runs from a working directory that is not the source tree"
want staged-in-cache           "staging data in /var/cache/gdash, which is the disposable half"
want publish                   "publish writes a snapshot"
want snapshot-in-state         "into /var/lib/gdash, which is the backup set"
want users-in-etc              "accounts land in /etc/gdash"
want users-restricted          "at mode 0600"
want served                    "and the server answers a dashboard request"
echo "--- uninstall ---"
want uninstalled               "make uninstall removes the program"
want data-survived-uninstall   "and leaves the dashboards alone"
want config-survived-uninstall "and the configuration"

echo "---"
echo "fhs: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || { echo; echo "--- container output ---"; echo "$out" | tail -20; exit 1; }
