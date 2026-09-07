# GDASH-8 — Deployment and operations: phase brief

**Status:** OPEN. Step-0 complete and written up in `gdash8_findings.md`
(G8-1 … G8-5). It found one blocker, which is fixed: gdash could only refresh
when started from its own repository.
**Narrows:** the GDASH-8 paragraph of `gdash_development_plan.md` (the phase
the numbering note calls deployment; it was GDASH-7 before GDASH-6 was
inserted).
**Authority:** `gdash_design.md` outranks this brief. The findings of GDASH-0
through GDASH-7 are inputs, not open questions.

This is the phase that turns a repository into something an operator can run.
Its deliverable is partly documentation, and the documentation is a deliverable
rather than a chore: nobody can stand up software whose dependencies, backup
set and failure modes are only in someone's head.

---

## 1. Step-0 verification

- **FHS mode had never executed** (G8-1) and now does, verified in a rootless
  container with the host's `/usr` mounted read-only — the only shape that
  works, since the interpreter links fifty shared libraries.
- **gdash could only refresh from its own repository** (G8-2): the child
  interpreter was located relative to the working directory. Fixed with
  `process.self()`. Second instance of G6-8, hidden the same way.
- **No install target, unit file or packaging exists** (G8-3).
- **The runtime dependency list is known** (G8-4), including two that need
  explaining rather than silently installing.
- **`systemd-analyze verify` checks a unit without booting** (G8-5), which is
  not the same as running under systemd.

## 2. Scope

### 2.1 The install

A `Makefile` with `install`, `uninstall` and `check`, honouring `DESTDIR` and
`PREFIX` so a packager can stage it. It creates the five FHS directories with
the modes design §6 requires, installs `src/*.bas` to `<prefix>/lib/gdash`, and
installs the units.

**No account creation, no `systemctl enable`, no daemon start.** An install
that starts a service is an install that surprises somebody; the documentation
says which two commands to run and why.

### 2.2 The FHS runner, as a permanent suite

`tests/run_fhs.sh`, opt-in on `GDASH_FHS_TEST=1` like the Postgres and LDAP
runners, doing what step-0 did by hand: install into a container at the real
paths, then validate, refresh, publish and serve a dashboard **with no
`GDASH_*` variable set at all**.

Without it the install rots the moment a path moves, and G8-2 shows that takes
one commit and nobody notices for eight phases.

### 2.3 The units

`gdash.service` and `gdash-scheduler.service` + `.timer`, hardened as the plan
names: `ProtectSystem=strict` with `ReadWritePaths` for exactly the four
writable roles, `CAP_NET_BIND_SERVICE` only if a privileged port is configured,
`NoNewPrivileges`, `PrivateTmp`, a dedicated unprivileged user, and
`WorkingDirectory` set — because G8-2 was a working-directory assumption and a
unit file is where that assumption is made explicit or made again.

`systemd-analyze verify` runs in the suite. **What it cannot do is start
anything**, so the DONE note will distinguish "the unit is well-formed" from
"the unit has run", and the second is the operator's first afternoon rather
than something this phase can claim.

### 2.4 Two things that have been deferred three times each

- **The session sweep.** `gdash_session.sweep` exists, is tested, and nothing
  calls it. `/run` clearing on reboot bounds the mess without bounding it well.
  The scheduler already runs on a timer and already walks the filesystem; this
  is one call in an existing pass.
- **Rate limiting on failed sign-in.** Deferred in GDASH-4 and again in
  GDASH-5, and it got worse in between: a directory is now behind the login
  form, where failed binds count toward somebody else's lockout policy.

  Workers share no in-memory state (design §5), so the counter is a file, like
  every other global fact in gdash: per-username failure counts under `/run`,
  with a delay that grows and an expiry that forgets. **Per username, not per
  address** — an intranet behind one NAT is one address, and locking out an
  address locks out a floor. It must never lock an account permanently: a
  denial-of-service against a named colleague is not a security feature.

### 2.5 TLS, and updates

- **TLS** is PLAT-WEB's, and `web.configure` now carries `cert` and `key`, so
  gdash's whole job is to read them from configuration and pass them through.
  Certificate acquisition, renewal and rotation are the deployment's.
- **Drain.** `serve` has an `on drain` hook and gdash uses none. A reload that
  drops in-flight requests is a bad upgrade story for a dashboard somebody is
  reading. What `on drain` can actually guarantee is measured before anything
  is claimed.

### 2.6 The operator's documentation

`docs/gdash_operations.md`, and it answers the questions an operator actually
has:

- What to install, including **why `libgirepository` and `libldap` are on the
  list** (G8-4) — a server operator installing a GTK dependency deserves the
  reason.
- **Backup and restore is one directory**: `/var/lib/gdash` is the entire
  backup set, `/var/cache/gdash` refetches, `/etc/gdash` is configuration a
  deployment already manages. Stated with a restore procedure that has been
  run, not asserted.
- **Worker sizing**, with the SSE ceiling stated plainly as the PLAT-WEB doc
  instructs — and G6-10 says gdash does not yet know the number. Either this
  phase measures it or the documentation says it is unknown and what that costs.
  It does not get a confident sentence with nothing behind it.
- Upgrades, log locations, and what each failure mode looks like from outside.

## 3. Construction rules

Unchanged, and additionally:

- **Nothing is claimed that has not run.** "The unit is well-formed" and "the
  service has started" are different sentences. So are "backup is one
  directory" and "a restore was performed from it".
- **No path literal outside the resolver**, which G6-8 and G8-2 both broke.
  The FHS runner is the check that keeps the third from hiding.
- **The install must be reversible.** `make uninstall` removes what `install`
  put there and nothing else — never a data directory, because an uninstall
  that deletes dashboards is a catastrophe wearing a helpful face.

## 4. Tests

- **The FHS runner** (§2.2), covering validate, refresh, publish and serve at
  real paths with no environment.
- **`--root` parity**: the same operations under `--root` and under FHS produce
  the same results, which is the assertion that the two modes have not drifted.
- **`systemd-analyze verify`** on every shipped unit.
- **Rate limiting**: a wrong password delays, a correct one after a delay still
  works, the counter expires, two users do not interfere, and no account can be
  locked permanently.
- **The sweep**: an expired session file is gone after a scheduler pass.
- **`make install` then `make uninstall`** leaves the filesystem as it was,
  except the data directories, which it must not touch.

## 5. Done means

1. `make install` puts gdash at FHS paths, and it runs there with no
   `GDASH_*` set.
2. The FHS runner is in the suite and would fail if a path moved.
3. Units exist, are hardened as §2.3 lists, and pass `systemd-analyze verify`.
4. The session sweep runs on the scheduler's pass.
5. A failed sign-in is rate limited per username, expiring, and cannot lock an
   account permanently.
6. TLS is configurable; the drain behaviour is measured and documented as
   whatever it turns out to be.
7. `docs/gdash_operations.md` answers install, backup, restore, sizing and
   upgrade, and every claim in it has been run.
8. All runners pass; findings recorded; the DONE note separates what ran from
   what was only verified statically.

## 6. Deliberately not built

Distribution packaging (`.deb`, `.rpm`) — a packager wants `DESTDIR`, which the
Makefile gives them, and a policy-compliant package is a distribution's job.
Certificate acquisition or renewal. Log rotation configuration, which is
logrotate's or journald's. Metrics, health endpoints and monitoring
integration: worth a phase of their own once somebody is running this and can
say what they watch. High availability, clustering, or any multi-host story —
gdash is one host with a filesystem, and design §5 is built on that. A
container image as a supported artifact: the container here is test tooling,
and shipping one is a distribution decision that would need its own lifecycle.
Init systems other than systemd.
