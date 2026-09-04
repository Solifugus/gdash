#!/usr/bin/env bash
# A real directory for gdash's opt-in LDAP runner.
#
# The platform's `ldap` module was written against a mock speaking real BER,
# and its own docs say it had never met AD or OpenLDAP. This stands up a real
# OpenLDAP 2.6.10 so gdash's provider is tested against a directory rather
# than against an agreement about one (finding G5-3).
#
# Rootless podman, no sudo, nothing installed on the host. The container is
# seeded with two users and three groupOfNames groups, and it deliberately
# does NOT enable the memberof overlay -- because stock OpenLDAP does not, and
# that absence is the thing gdash has to handle (finding G5-4).
#
#   scripts/ldap_test_directory.sh up      build if needed, run, wait for it
#   scripts/ldap_test_directory.sh down    stop and remove
#   scripts/ldap_test_directory.sh env     print the exports the runner wants
#
# Every credential here is obviously fake and local to a throwaway container.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE=gdash-ldap-test
NAME=gdash-ldap
PORT="${GDASH_LDAP_PORT:-3890}"
BUILD="$HERE/ldap_test_directory.d"

need_podman() {
    command -v podman >/dev/null 2>&1 || {
        echo "podman is not installed; the live LDAP runner needs it" >&2
        exit 2
    }
}

write_build_context() {
    mkdir -p "$BUILD"
    cat > "$BUILD/seed.ldif" <<'LDIF'
dn: ou=people,dc=example,dc=invalid
objectClass: organizationalUnit
ou: people

dn: ou=groups,dc=example,dc=invalid
objectClass: organizationalUnit
ou: groups

dn: uid=ada,ou=people,dc=example,dc=invalid
objectClass: inetOrgPerson
uid: ada
cn: Ada Okonjo
sn: Okonjo
mail: ada@example.invalid
userPassword: fake-directory-pw

dn: uid=bo,ou=people,dc=example,dc=invalid
objectClass: inetOrgPerson
uid: bo
cn: Bo Lindqvist
sn: Lindqvist
mail: bo@example.invalid
userPassword: another-fake-pw

dn: uid=gone,ou=people,dc=example,dc=invalid
objectClass: inetOrgPerson
uid: gone
cn: Departed Person
sn: Person
mail: gone@example.invalid
userPassword: third-fake-pw

dn: cn=analysts,ou=groups,dc=example,dc=invalid
objectClass: groupOfNames
cn: analysts
member: uid=ada,ou=people,dc=example,dc=invalid

dn: cn=finance,ou=groups,dc=example,dc=invalid
objectClass: groupOfNames
cn: finance
member: uid=ada,ou=people,dc=example,dc=invalid

dn: cn=shipping,ou=groups,dc=example,dc=invalid
objectClass: groupOfNames
cn: shipping
member: uid=bo,ou=people,dc=example,dc=invalid
LDIF
    cat > "$BUILD/Containerfile" <<'EOF'
FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq slapd ldap-utils && rm -rf /var/lib/apt/lists/*
RUN echo "slapd slapd/no_configuration boolean false"   | debconf-set-selections \
 && echo "slapd slapd/domain string example.invalid"    | debconf-set-selections \
 && echo "slapd shared/organization string Example"     | debconf-set-selections \
 && echo "slapd slapd/password1 password fake-admin-pw" | debconf-set-selections \
 && echo "slapd slapd/password2 password fake-admin-pw" | debconf-set-selections \
 && rm -rf /etc/ldap/slapd.d /var/lib/ldap/* \
 && dpkg-reconfigure -f noninteractive slapd
COPY seed.ldif /seed.ldif
RUN slapd -h "ldap://127.0.0.1:389/" -u openldap -g openldap & \
    sleep 3 && \
    ldapadd -x -D "cn=admin,dc=example,dc=invalid" -w fake-admin-pw -f /seed.ldif && \
    pkill slapd && sleep 1
EXPOSE 389
CMD ["slapd", "-d", "0", "-h", "ldap://0.0.0.0:389/", "-u", "openldap", "-g", "openldap"]
EOF
}

case "${1:-up}" in
up)
    need_podman
    write_build_context
    if ! podman image exists "$IMAGE" 2>/dev/null; then
        echo "building $IMAGE (first run only) ..."
        podman build -t "$IMAGE" "$BUILD" >/dev/null || { echo "build failed" >&2; exit 1; }
    fi
    podman rm -f "$NAME" >/dev/null 2>&1
    podman run -d --name "$NAME" -p "$PORT:389" "$IMAGE" >/dev/null || exit 1
    for _ in $(seq 1 60); do
        (echo > "/dev/tcp/127.0.0.1/$PORT") >/dev/null 2>&1 && break
        sleep 0.5
    done
    (echo > "/dev/tcp/127.0.0.1/$PORT") >/dev/null 2>&1 || { echo "directory did not come up" >&2; exit 1; }
    echo "directory listening on 127.0.0.1:$PORT"
    ;;
down)
    need_podman
    podman rm -f "$NAME" >/dev/null 2>&1
    echo "directory stopped"
    ;;
env)
    cat <<ENVV
export GDASH_LDAP_TEST=1
export GDASH_LDAP_HOST=127.0.0.1
export GDASH_LDAP_PORT=$PORT
export GDASH_LDAP_BASE='dc=example,dc=invalid'
export GDASH_LDAP_BIND_DN='cn=admin,dc=example,dc=invalid'
export GDASH_LDAP_BIND_PW='fake-admin-pw'
ENVV
    ;;
*)
    echo "usage: $0 up|down|env" >&2
    exit 2
    ;;
esac
