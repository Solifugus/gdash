# GDASH-8 — Findings

**Status:** step-0 complete. It found one blocker, fixed it, and FHS mode now
runs for the first time in the project's life.
**Platform:** gBASIC `ca5df46`.

---

## G8-1 — FHS mode had never executed, and now has

Every test, every runner and every phase from GDASH-0 through GDASH-7 ran under
`--root` in a temporary directory. `gdash_paths.roles("")` returns `/etc/gdash`,
`/var/lib/gdash`, `/var/cache/gdash`, `/var/log/gdash` and `/run/gdash`, and
`test_paths` asserted those **strings**. Nothing had ever written to them.

Verifying it needed root, which this account does not have:

- `sudo -n` — refused.
- `unshare --map-root-user` — `write failed /proc/self/uid_map: Operation not
  permitted`. User namespaces are restricted directly.
- **`podman` works**, rootless, because it goes through the setuid helpers. The
  same tool that gave GDASH-5 a real LDAP directory gives GDASH-8 a real root
  filesystem.

The interpreter links **fifty** shared libraries — `libpq`, `libsqlite3`,
`libldap`, `libcurl-gnutls`, `libssl`, `libxml2`, `libgirepository` among them
— so a slim base image cannot run it and a matching-distro image segfaulted
(host Ubuntu 26.04 libraries against a 24.04 loader). What works is mounting
the host's `/usr`, `/lib` and `/lib64` read-only into any base image: the real
interpreter, the real libraries, and an empty `/etc`, `/var` and `/run` that is
exactly the install target.

With the blocker below fixed, gdash installed at `/opt/gdash`, started from
`/`, **with no `GDASH_*` variable set at all**, validates a dashboard, refreshes
both its datasets, and writes them to `/var/cache/gdash/sales/draft/`.

## G8-2 — gdash could only refresh when started from its own repository

```
refresh failed: src/gdash_refresh_child.bas: No such file or directory
```

`gdash_refresh._child_script()` returned `env("GDASH_SRC")` or the literal
`"src"`, joined to the child's filename — **relative to the working
directory**. A refresh therefore worked only from the repository root. Started
by a service manager, or installed anywhere at all, every refresh failed.

The comment above it said "The child lives beside this module". The code did
not do that; it hoped the working directory was where the module lived.

This is **G6-8 again** — the chart library loaded by a relative path into the
sibling gbasic checkout — and it hid for the same reason: every process gdash
starts is started from the repo root, so the assumption was true everywhere
anyone looked. CLAUDE.md has said since GDASH-0 that no path literal belongs
outside the resolver, and this is the second one found by moving the code
somewhere it had never been.

`process.self()` reports the **absolute** path of the running interpreter and
script however the process was invoked, so the child is now located beside
whatever program is running — `gdash_cli.bas` and `gdash_server.bas` both sit
next to it. The interpreter defaults the same way rather than trusting `PATH`.
`GDASH_SRC` survives as an override, which is how the suite points at `src/`
while running a program out of `tests/`.

## G8-3 — there is no install target, no unit file, no packaging

Not a defect; the starting position, recorded so the phase's size is honest.
`find` turns up no `Makefile`, no `*.service`, no packaging directory, and no
install script. Everything gdash knows about deployment is the resolver's five
paths and a design section describing them.

## G8-4 — what a gdash host actually needs

Fifty shared libraries, and the ones that are not base-system are the
deployment's dependency list rather than a curiosity: `libpq5`,
`libsqlite3-0`, `libodbc2`, `libldap-2.5`, `liblber-2.5`, `libcurl3-gnutls`,
`libssl3`, `libcrypto3`, `libxml2`, `libcrypt1`, `libgirepository-2.0`.

Two of those deserve a note in the deployment documentation rather than a
silent dependency: `libldap` is only needed by deployments that use directory
auth, and `libgirepository` is pulled in by the interpreter's GUI support,
which a server has no use for. Whether the platform can be built without them
is the platform's question, not gdash's — but a server operator installing a
GTK dependency to serve dashboards deserves to be told why.

## G8-5 — unit files can be checked without booting

`systemd-analyze` is on the host, so `systemd-analyze verify` gives the unit
file's syntax and directive names a real check without a service manager, a
reboot, or root. That is not the same as running under systemd, and the DONE
note will say which of the two the phase achieved.

## G8-6 — a TLS-configured server listens in cleartext

`web.configure` accepts `cert` and `key`, stores them (the merged declaration's
`options` carries both), and `serve` ignores them — it reads the TLS pair from
the pre-registered head instead. Measured with one certificate, both ways:

```
cert/key IN THE HEAD          https=200   http=000    TLS on, cleartext refused
cert/key VIA web.configure    https=000   http=200    TLS OFF, cleartext served
```

`port` and `workers` from the same merge do take effect, which is what makes it
hard to notice: everything else you configure works.

**gdash refuses to start when TLS is configured**, rather than serve cleartext
while printing "TLS from …". It cannot verify — the record `serve` returns has
no TLS field — so it cannot pretend. An operator who configured TLS and got
cleartext is worse off than one who was told to use a reverse proxy: the first
believes they are encrypted.

The refusal is temporary and says so, and the test that pins it will go red
when the platform carries the pair through, which is how gdash will notice.
Reported in `gdash8_platform_report_tls.md`.

Worth naming the near miss: the first version of this code printed
`gdash: TLS from /path/cert.pem` and served cleartext. It was written, it ran,
and the log line was a lie. What caught it was refusing to write "TLS is
configurable" into the operations document without running it — which is the
rule this phase's brief opens with.
