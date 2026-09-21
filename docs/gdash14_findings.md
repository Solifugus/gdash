# GDASH-14 findings

## G14-1 — the install's own first-run sequence leaves the service unable to refresh

**Found by the first `systemctl start` in the project's history**, which is the
entire argument for this phase.

```
gdash[224]: /var/cache/gdash/timed/published/orders.lock: No such file or directory
gdash[224]: runtime error at gdash_refresh.bas:237: could not write file:
            /var/cache/gdash/timed/published/orders.lock
systemd[1]: gdash-scheduler.service: Failed with result 'exit-code'.
```

### The sequence, and it is the documented one

`make install` creates the four data roles **root-owned**, because the service
account may not exist yet. The install message then says to create the account
and start the service — and the Makefile's own comment explains that the roles
exist from install onward *"because the CLI is run by an administrator before
the service has ever started"*.

So an administrator validates and refreshes a dashboard as root. That creates
`/var/cache/gdash/<dashboard>/` owned by **root**, inside `/var/cache/gdash`,
which `CacheDirectory=` then chowns to `gdash` at first start. The top level is
fixed; what the CLI made underneath it is not:

```
/var/cache/gdash                    gdash:gdash 755
/var/cache/gdash/timed              root:root   755     <- the CLI made this
/var/cache/gdash/timed/draft        root:root   755
```

The service, as `gdash`, then cannot create `published/` inside it.

### Three defects, not one

1. **`ensure_dir`'s result was assigned and dropped.** `made = ensure_dir(...)`,
   twice, with no check. A directory that could not be created was simply
   proceeded past.

2. **The failing write left an error pending and unacknowledged.** The lock-file
   write is inside `on error goto next`, so it did not raise — it set the flag.
   Nothing checked it, and the `with lock(lf)` three lines later **raised into a
   pending error and escaped the frame**. This is precisely the platform hazard
   gdash's own notes record ("one pending error at a time; a raise arriving
   while an unacknowledged error is pending escapes the frame. Check
   promptly") — written down, then met anyway.

3. **`pass()` had no guard, so one dashboard killed every other one.** `pass`
   counts failures and was built to be resilient; a raise bypasses counting
   entirely. A single misconfigured dashboard turned into a total scheduling
   outage, silently, because the unit simply exited non-zero.

Of the three, (3) is the one that turns a local problem into a global one.

### Fixed, and what it says now

```
gdash[283]: timed.orders:  cannot create the data directory /var/cache/gdash/timed/published
                           (check that the service user owns it and every directory above it)
gdash[283]: timed.regions: cannot create the data directory /var/cache/gdash/timed/published
                           (check that the service user owns it and every directory above it)
gdash[283]: schedule: 2 checked, 0 refreshed, 0 unchanged, 2 failed, 0 sessions swept
```

Both datasets reported, a total at the end, and a message naming the path and
the thing to check. The install message gained the missing `chown` step, and
operations §2 gained `runuser -u gdash -- gdash ...` as the way to avoid the
trap entirely.

## G14-2 — `systemd-analyze verify` cannot ask the question that mattered

Verify has passed on these units for six phases. It checks that a unit
**parses**. Every defect in G14-1 sits on the far side of that: whether
`ProtectSystem=strict` and an empty `CapabilityBoundingSet` let gdash fork an
interpreter, whether `StateDirectory=` produced writable directories, whether
the service account can reach what the CLI left behind.

The distinction is worth stating because it generalises: *a check that a
configuration is well-formed is not a check that it works*, and the gap between
them is where "it verified fine" lives.

## G14-3 — operations §10 asserted a reason that was false

> The units have been checked with `systemd-analyze verify`, not started. …
> there is no systemd in the container used for testing.

The first clause was true. The second was an **assumption recorded as a
fact**, and it was wrong: rootless podman boots systemd as PID 1 with
`--systemd=always --cap-add=all`, and has been able to for years.

A documented limitation with a stated cause is much harder to revisit than one
that says "not done yet" — the reason reads as a finding and stops anyone
looking. Recorded because the same sentence pattern is easy to write again.

## G14-4 — the timer is excluded from the Makefile's substitution

`gdash.service` and `gdash-scheduler.service` carry `@BINDIR@` and `@DOCDIR@`
and are rewritten at install. `gdash-scheduler.timer` is not in that `sed`
list, and hardcodes:

```
Documentation=file:/usr/local/share/doc/gdash/gdash_operations.md
```

Cosmetic, because `Documentation=` is informational and a wrong path there
breaks nothing. It is still a unit that lies about where its documentation is
for any `PREFIX` other than `/usr/local`, and the suite now asserts that no
`@PLACEHOLDER@` survives in any installed unit — which would have caught the
opposite and worse version of this.

## G14-5 — two assertions passed on another invocation's journal

Both while writing the runner, and both the same shape.

`journalctl -u gdash-scheduler --since '-30s'` also catches the **previous**
run of a oneshot. A needle from the earlier *successful* invocation made "the
pass still reports a total rather than stopping" pass while the pass was in
fact dying — the needle was real, it just belonged to a different run.

`_SYSTEMD_INVOCATION_ID` looked like the precise fix and is not: it comes back
**empty** for a oneshot that has already exited, so the filtered read returned
nothing and every `grep`-for-absence assertion passed vacuously.

What works is a **journal cursor** taken immediately before the start, read
back with `--after-cursor`. Both failure modes are now pinned by a
`yes_ "the failing invocation logged something at all"` assertion, which is
what stops an empty read from looking like a clean one.

This is the fourth time in three phases that an assertion has been found
passing for the wrong reason. The pattern is always the same: **the needle was
correct and the haystack was wrong.**
