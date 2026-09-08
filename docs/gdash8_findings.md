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

## G8-7 — in-flight requests survive a shutdown; `on drain` fires in only one shape

The brief said to measure what `on drain` guarantees before claiming anything.
SIGTERM to the supervisor, one second into a four-second handler, repeated at
both worker counts:

| workers | in-flight request | `on drain` fired |
|---|---|---|
| 1 | completed, 200, full body | yes |
| 4 | completed, 200, full body | **no** |
| 1 | completed, 200, full body | yes |
| 4 | completed, 200, full body | **no** |

**gdash gets graceful shutdown for free, and adds no drain hook.** Two reasons,
and the first is sufficient: workers share no in-memory state (design §5), so
there is nothing to flush — the sessions are files, the staged data is files,
and a half-finished refresh leaves its staging file for the next pass to sweep.
The second is that a hook firing in only one configuration is worse than no
hook, because it is tested single-process and shipped multi-process.

So the upgrade story is: **`systemctl restart` completes the requests it is
serving.** That sentence is now measured rather than hoped, which is the whole
reason the brief asked for a measurement instead of a claim.

The inconsistency is reported for the next caller, who will have state to flush
and will test it at one worker.

## G8-8 — a measurement voided by a rebuild, and repeated

The first multi-worker attempt returned `code=000` everywhere and a log saying
`gbasic: No such file or directory` — the interpreter was being rebuilt
underneath the test. The result was discarded rather than interpreted.

Recorded because the temptation was to read it as "the supervisor drops
in-flight requests", which is a plausible and completely wrong conclusion that
would have gone into the operations document. It is the same lesson as G7-10,
in a phase whose brief opens with "nothing is claimed that has not run" -- the
corollary being that something which ran on a moving platform has not run
either.

## G8-9 — the SSE ceiling is exactly the worker count, and G6-10 is closed

GDASH-6 could not separate worker pinning from `curl` buffering and left the
number unknown. Counting how many streams "opened" was the wrong measurement.
The right one is small and decisive: hold every worker with a stream, then ask
for an ordinary page.

Two workers, two streams, both confirmed established:

```
baseline GET /                    200
GET /  while both held            000  (no answer in 8s)
GET /d/sales while both held      200  in 4.6s -- served only after a stream expired
```

**An open dashboard holds a worker for as long as it is open.** gdash's page
opens an `EventSource`, so every browser tab with a dashboard on it occupies
one worker, and a request arriving when all workers are held is not queued
briefly — it is not answered until somebody closes a tab.

The sizing rule follows and is not a guess: **workers must exceed the number of
dashboards open at once**, with headroom for ordinary requests on top. A
four-worker gdash serves three simultaneous viewers.

That is the sentence the plan asked to be "stated plainly", and it is a real
constraint rather than a caveat: an office of twenty people leaving dashboards
open on a wall needs more than twenty workers, and each is a process.

Recorded as a limitation rather than fixed. Making a stream cost less than a
worker is the platform's architecture, not gdash's — and the honest thing in an
operations document is the number, not a workaround.
