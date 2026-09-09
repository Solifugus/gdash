# Running gdash

Every claim in this document has been executed. Where something has only been
checked statically, it says so.

---

## 1. What the host needs

The gBASIC interpreter, and the libraries it links. On a Debian or Ubuntu host:

```
libpq5 libsqlite3-0 libodbc2 libldap-2.5-0 libcurl3-gnutls
libssl3 libxml2 libcrypt1 libgirepository-2.0-0
```

Three of those deserve an explanation rather than a silent install:

- **`libldap`** is needed only if you use directory authentication. Local
  accounts need nothing from it.
- **`libgirepository`** comes from the interpreter's GUI support, which a
  dashboard server never uses. It is a dependency of the interpreter, not of
  gdash.
- **`libodbc`** is needed only if a connection profile has `"kind": "odbc"` —
  and then **the driver for your database must be installed too**, which is a
  separate package per vendor (`msodbcsql18`, `odbc-mariadb`,
  `libsqliteodbc`, …). `gdash source check <profile>` lists what the host can
  actually load, which turns "it will not connect" into a sentence.

## 2. Install

```sh
make install                      # PREFIX=/usr/local by default
useradd --system --no-create-home --shell /usr/sbin/nologin gdash
systemctl enable --now gdash gdash-scheduler.timer
```

`make install` deliberately does **not** create the account, enable a unit or
start anything. An install that starts a service is an install that surprises
somebody.

`DESTDIR` and `PREFIX` are honoured, so a packager can stage it. The units are
templated at install time: `PREFIX=/opt/gdash` produces units that name
`/opt/gdash/bin`, not `/usr/local/bin`.

**Both units matter.** The server serves; the timer refreshes. A deployment
that starts only `gdash` has dashboards that never update, and nothing will say
so — the pages will simply show old "data as of" timestamps.

## 3. Where things live

| path | what | back it up? |
|---|---|---|
| `/etc/gdash` | connections, accounts, auth, theme, CSRF secret | yes — it is configuration |
| `/var/lib/gdash` | dashboards, snapshots, `current` pointers | **yes — this is the backup set** |
| `/var/cache/gdash` | staged data, per dashboard and mode | no — it refetches |
| `/var/log/gdash` | the audit log | as your policy requires |
| `/run/gdash` | sessions, sign-in counters | no — cleared on reboot, correctly |

`/etc/gdash/users.json`, `/etc/gdash/auth.json` and `/etc/gdash/secret` are
mode 0600 and contain password hashes, a directory service account and the CSRF
secret. Everything else in `/etc/gdash` is ordinary configuration.

## 4. Backup and restore

**The backup set is one directory.** Add `/etc/gdash` if your configuration is
not already managed elsewhere.

```sh
tar -C / -czf gdash-backup.tgz var/lib/gdash etc/gdash
```

To restore:

```sh
systemctl stop gdash gdash-scheduler.timer
tar -C / -xzf gdash-backup.tgz
systemctl start gdash gdash-scheduler.timer
gdash refresh <dashboard>          # or wait for the timer
```

**This has been performed, not assumed.** `tests/run_fhs.sh` backs up
`/var/lib/gdash`, destroys both data directories, restores only the backup, and
requires the dashboard, its published history and a working refresh to come
back. `/var/cache/gdash` is not in the backup and does not need to be.

## 5. Sizing, and the one hard limit

**A dashboard open in a browser holds a worker for as long as it is open.**

The page opens a server-sent-event stream so that a refresh or a publish
reaches it, and that stream occupies one worker until the tab closes. Measured:
with two workers and two dashboards open, an ordinary request is **not
answered** — not delayed, not queued briefly, but unanswered until one of the
streams ends.

So:

```
workers  >  dashboards open at once  +  headroom for ordinary requests
```

A four-worker gdash serves three simultaneous viewers. An office of twenty
people leaving dashboards up needs more than twenty workers, and each worker is
a process. Set it in `/etc/gdash/environment`:

```
GDASH_WORKERS=24
```

This is a real constraint, not a caveat. If dashboards intermittently fail to
load and nothing appears in the log, this is why.

## 6. Configuration

`/etc/gdash/environment`, read by both units:

| variable | default | meaning |
|---|---|---|
| `GDASH_WORKERS` | 1 | see §5; a configured `0` is treated as 1 |
| `GDASH_PORT` | 8780 | |
| `GDASH_ADDRESS` | all interfaces | bind to one interface |
| `GDASH_GBASIC` | `gbasic` on PATH | the interpreter |

### TLS

**Terminate TLS at a reverse proxy.** gdash refuses to start if
`GDASH_TLS_CERT` and `GDASH_TLS_KEY` are set, because the platform accepts them
and then serves in cleartext — it would look encrypted and would not be
(`gdash8_platform_report_tls.md`). Refusing is deliberate: an operator who
configured TLS and got cleartext is worse off than one who was told to use a
proxy.

Design §6 recommends TLS rather than requiring it, and gdash sets the session
cookie's `Secure` flag from `req.scheme` — so a proxy that speaks HTTPS to the
browser and forwards the scheme gets the right behaviour.

## 7. Upgrades

```sh
make install
systemctl restart gdash
```

**A restart completes the requests it is serving.** Measured: SIGTERM one
second into a four-second request returns the whole response, at one worker and
at four. Open dashboards will reconnect their event streams; viewers see
nothing.

## 8. What failure looks like

| symptom | cause | where to look |
|---|---|---|
| pages load, data never changes | the timer is not enabled | `systemctl list-timers gdash*` |
| a dashboard shows "last refresh failed" | the source is unreachable or the query changed | `/var/log/gdash/audit.log` |
| dashboards intermittently do not load | more open dashboards than workers | §5 |
| sign-in says "try again in N seconds" | rate limiting after three failed attempts | expires after 15 quiet minutes |
| sign-in says "unavailable" | the directory is down — **not** a wrong password | `audit.log`, `login.unavailable` |
| a chart is blank with an error box | a `line` mark over a text x column | use `bar`, or return a number |
| a refresh says "cannot connect to source" | wrong host, or the ODBC driver is not installed | `gdash source check <profile>` |
| everything refuses after an edit | a record failed validation | `gdash validate <name>` |

The audit log is JSON lines: logins, failures, throttling, publishes,
rollbacks, refreshes, access denials and preview-as. It never contains a
password, a connection string or an attribute from a directory.

## 9. Administration

```sh
gdash validate <name>            # before anything else
gdash refresh <name> [dataset]   # what it serves; --draft for the draft
gdash publish <name>             # draft -> a new snapshot
gdash rollback <name> [snapshot] # repoint `current`
gdash snapshots <name>           # what has been published
gdash diff <name> [from] [to]    # what changed between two versions
gdash user add|passwd|groups|disable|enable|remove|list
gdash auth check <username>      # what the directory actually returns
gdash source check [profile]     # which drivers the host has, and whether it connects
gdash schedule                   # one refresh pass, by hand
```

Authoring is the record file itself: edit `draft.json`, `gdash validate`, then
`gdash publish`. There is no designer UI and no second way to publish.

## 10. What has not been run

Honesty about the gap between this document and a running system:

- **The units have been checked with `systemd-analyze verify`, not started.**
  Every directive is accepted and the templating is verified, but no `systemctl
  start` has happened in this environment — there is no systemd in the
  container used for testing. The first real start is your afternoon.
- **The install, refresh, publish, serve, backup and restore have all run** at
  real FHS paths as root, in a container, with no `GDASH_*` set.
- **TLS has not been served by gdash**, because it cannot be yet (§6).
