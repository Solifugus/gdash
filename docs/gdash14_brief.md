# GDASH-14 — The units, actually started

**Status:** COMPLETE. Findings in `gdash14_findings.md` (G14-1 … G14-5).
**Authority:** `gdash_design.md` outranks this brief.

## Why this phase, and why now

Not new work — **G8-7, become blocking.** `systemd-analyze verify` has accepted
every directive since GDASH-8 and no `systemctl start` had ever happened.
Operations §10 said so in as many words, and gave the reason:

> there is no systemd in the container used for testing

Under the no-failover ruling (2026-09-15) the operating model is *"we restart
things and that is fine"*, which makes an untested restart the weakest link in
everything that follows — including every multi-tenancy phase after this one.

## Step 0

### S0-1 — the stated reason was wrong

Rootless podman boots systemd as PID 1 given `--systemd=always` and
`--cap-add=all`, on this machine, today:

```
$ podman exec ... systemctl is-system-running
running
$ podman exec ... systemctl --version
systemd 259 (259.5-0ubuntu3.4)
```

The host's `/usr`, `/lib` and `/lib64` mount read-only so the interpreter's
shared libraries resolve — exactly what `run_fhs.sh` already does. So the
fidelity available is **full**: real systemd, real root, real FHS paths, the
real units as the Makefile installs them, and the real hardening.

Two constraints found on the way, both container-side and neither a gdash
defect: without `--cap-add=all`, `User=` fails at `step USER` because systemd
cannot keep `CAP_SYS_ADMIN` to set up the sandbox; and the account needs a
subuid range (it has one: 100000:65536).

### S0-2 — `systemctl --user` also works, and is the weaker option

The host runs a user manager and it will start a unit. It cannot exercise
`User=`, `StateDirectory=` at FHS paths, or most of the hardening, so it is
recorded as a fallback rather than used.

### S0-3 — the timer is excluded from the Makefile's substitution

`gdash.service` and `gdash-scheduler.service` are templated with `@BINDIR@` and
`@DOCDIR@` and rewritten at install. `gdash-scheduler.timer` is not in that
`sed`, and hardcodes `/usr/local/share/doc/gdash/...` in its `Documentation=`.
Cosmetic — `Documentation=` is informational — but wrong for any install with a
different `PREFIX`, and now asserted against.

## What starting them found

**The first start of the scheduler unit failed with a runtime error** (G14-1),
and the cause is a sequence the install's own message prescribes. Detail in the
findings; the short form is that the CLI run by an administrator before the
service exists leaves directories the service user cannot write into, and gdash
crashed rather than saying so — taking every other dashboard's refresh down
with it.

## Scope

1. A runner that boots systemd and exercises the real lifecycle: enable, start,
   serve, restart, kill, timer, stop, uninstall.
2. Fix what starting them found.
3. Correct operations §10, which asserted something false.
4. The install message, which is missing a step.
5. Write down the `gdash-scheduler@tenant` shape for GDASH-15.

## Deliberately not built

- **A reboot test.** Restarting the container is not a host reboot, and the
  interesting part of a reboot — `/run` cleared, `Persistent=true` catching up
  one missed timer pass — is asserted at the unit level instead.
- **A drain test under systemd.** `run_drain.sh` already pins the drain promise
  against SIGTERM, which is what `systemctl restart` sends. What this adds is
  that a restart leaves the service active and serving with a new main process.
- **Socket activation, `systemd-notify`, `Type=notify`.** gdash is `Type=simple`
  and starting it proved that is enough. `Type=notify` would let systemd know
  when the port is actually open, which is worth having the day a dependency
  orders against it, and not before.
- **Hardening beyond what ships.** `ProtectProc=`, `PrivateUsers=`,
  `SystemCallFilter=` are all plausible additions. Adding them now would be
  adding directives nothing has asked for to a unit that has just been started
  for the first time.

## DONE

`tests/run_systemd.sh` — **37 assertions**, opt-in on `GDASH_SYSTEMD_TEST=1`,
wired into `run_tests.sh` beside the FHS suite. It boots systemd as PID 1,
installs at real FHS paths, creates the service account, and then:

- `systemctl enable --now gdash` → active, enabled, zero restarts to get there
- all four `StateDirectory=` roles exist as `gdash:gdash`
- the main process runs as the service account, not root
- it serves `/` and renders `/d/sales`
- the scheduler oneshot succeeds **under full hardening**, which is the question
  `verify` cannot ask: `ProtectSystem=strict`, `NoNewPrivileges`, an empty
  `CapabilityBoundingSet` and `RestrictNamespaces` did not stop gdash forking an
  interpreter to fetch data
- the G14-1 regression, pinned: a root-owned data directory produces a message
  naming the path and what to check, and the pass still reports a total
- `systemctl restart` → active, new main PID, serving, not counted as a failure
- `kill -9` the supervisor → `Restart=on-failure` brings it back and serves
- the timer is active and listed in `list-timers`
- `systemctl stop` → inactive, clean, and the dashboards and cache survive it
- `make uninstall` removes the units and leaves the data

Verified by mutation: reverting the G14-1 fix fails four of that block's five
assertions, including a runtime error escaping into the journal.

Fixed: `gdash_refresh.run` checks `ensure_dir` and checks the lock-file write
**promptly**, and `gdash_refresh.pass` guards each dataset so a raise becomes a
counted failure. Two new in-process assertions in `test_refresh.bas` pin both
without needing a container.

Corrected: operations §10's false claim, operations §2 (the chown step and the
`runuser` alternative), and the install message, which named two remaining
steps when there are three.

Suite: 36 suites 0 failed, plus systemd 37 and FHS 22 on the opt-in runners.
