# Running gdash

Every claim in this document has been executed. Where something has only been
checked statically, it says so.

---

## 1. What the host needs

The gBASIC interpreter, and the libraries it links. On a Debian or Ubuntu host:

```
libpq5 libsqlite3-0 libodbc2 libldap-2.5-0 libcurl3-gnutls
libssl3 libxml2 libcrypt1 libgirepository-2.0-0 libpcre2-8-0
```

gdash stages its data in G-SQL, which is part of the interpreter, so there is
no database to install. It needs a gBASIC build at or after `e902acf`
(`gbasic --version` prints `0.10.0+<rev>`), and builds since then link PCRE2.
`libsqlite3` is still linked by the interpreter; gdash itself no longer uses
it.

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

**Give the service account the data roles before running anything.** `make
install` creates `/etc/gdash`, `/var/lib/gdash`, `/var/cache/gdash` and
`/var/log/gdash` **root-owned**, because the account may not exist yet:

```sh
useradd --system --no-create-home gdash
chown -R gdash:gdash /etc/gdash /var/lib/gdash /var/cache/gdash /var/log/gdash
```

**Do this before you run `gdash` as root.** systemd's `StateDirectory=` and
friends fix the ownership of the four top-level directories when the service
first starts, but not of anything the CLI created inside them first — so an
administrator who validates and refreshes a dashboard before starting the
service leaves `<cache>/<dashboard>/` owned by root, and the service then
cannot create the published data directory inside it. gdash reports that
clearly now rather than crashing (G14-1), but the refresh still fails until the
ownership is fixed. Running the CLI as the service account avoids it entirely:

```sh
runuser -u gdash -- gdash validate sales
```

## 3. Where things live

| path | what | back it up? |
|---|---|---|
| `/etc/gdash` | connections, accounts, auth, theme, CSRF secret | yes — it is configuration |
| `/var/lib/gdash` | dashboards, snapshots, `current` pointers | **yes — this is the backup set** |
| `/var/cache/gdash` | staged data: one G-SQL database per dashboard and mode, `<dashboard>/<mode>/data.gsql` | no — it refetches |
| `/var/log/gdash` | the audit log | as your policy requires |
| `/run/gdash` | sessions, sign-in counters | no — cleared on reboot, correctly |

`/etc/gdash/users.json`, `/etc/gdash/auth.json` and `/etc/gdash/secret` are
mode 0600 and contain password hashes, a directory service account and the CSRF
secret. `/etc/gdash/connections.json` and `/etc/gdash/models.json` hold source
and model credentials and should be treated the same way. Everything else in
`/etc/gdash` is ordinary configuration.

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

**The staged data is served by G-SQL owner processes.** Each dashboard's
database is a directory, served by one `gbasic --gsql-owner` process that the
first worker or refresh to touch it starts, and that stops by itself once
nothing has used it for its linger: 30 seconds by default, set with
`GDASH_GSQL_LINGER` (seconds) in `/etc/gdash/environment`. A dashboard nobody
is looking at has no process. `systemctl stop gdash` stops the owners with the
rest of the service, each cleanly. Delete `/var/cache/gdash` only while the
service is stopped, as before. One limit is known and asked of the platform
(`gdash20_platform_ask_gsql.md` A1): an owner's socket lives in a per-user
directory that `PrivateTmp` separates between the server and the scheduler
units, so the units must not be relied on to refresh a dashboard someone has
open until that lands.

## 5. Sizing

**An open dashboard no longer holds a worker.** It did until GDASH-11, and the
consequence was severe enough to be worth stating plainly here rather than
only in a findings file: gdash served **one fewer viewer than it had workers**
— at the default of one worker, none. Not slowly. Not intermittently. A second
request was not answered at all until the first tab was closed.

The cause was gdash's own stream handler, which looped in `sleep(0.5)` until
the client went away; a handler that never returns is a worker that never
comes back. (Not a property of server-sent events, which can be kept alive by
a handler that returns — see `gdash11_findings.md` G11-13.)

The browser now polls `/d/{name}/version` every five seconds instead, and a
worker is busy only for the few milliseconds that takes. **That stays true at
any worker count**, which is why gdash polls rather than pushing: a held
connection belongs to the one worker that accepted it, so notifying every
viewer would mean running a single worker, and workers are what keep a burst
of page loads from queueing.

### What a request costs

Measured on one worker, sequentially, against the reference dashboard:

| request | cost |
|---|---|
| `GET /d/{name}/version` — the poll every open tab makes | 28 ms |
| `GET /d/{name}` — a full page, every visual queried | 57 ms |
| `GET /whoami` | 6 ms |

So one worker is about 35 polls per second, and a viewer with a tab open makes
0.2 of those — where before, that viewer occupied a whole process.

### What it takes under load

Measured, not extrapolated. Simulated viewers polling every five seconds the
way the page does, while somebody loads a page:

| workers | viewers | polls | failed | worst page load |
|---|---|---|---|---|
| 1 (default) | 10 | 30 | 0 | 87 ms |
| 1 (default) | 30 | 90 | 0 | 71 ms |
| 4 | 30 | 90 | 0 | 71 ms |

Thirty people with dashboards open cost the default single worker nothing
measurable. Before GDASH-11 that configuration served **nobody**.

What workers are actually for is a **burst of page loads**, which is the
expensive request:

| workers | simultaneous page loads | failed | slowest |
|---|---|---|---|
| 1 | 4 | 0 | 181 ms |
| 1 | 10 | 0 | 482 ms |
| 1 | 20 | 0 | 951 ms |
| 4 | 4 | 0 | 166 ms |
| 4 | 10 | 0 | 195 ms |
| 4 | 20 | 0 | 675 ms |

Nothing fails at any of these; page loads queue, and the queue is the whole
effect. One worker renders about twenty pages a second in series, so it takes
a genuinely simultaneous crowd to be noticed.

### Choosing a number

Size for **page loads arriving at once**, not for tabs left open:

```
workers  ≈  how many people plausibly open a dashboard in the same second
```

The default of one is enough to try gdash and enough for a handful of people.
Four covers an office arriving at nine o'clock. Each worker is a process, so
there is no reason to go far past that until a measurement says so.

```
GDASH_WORKERS=4
```

The poll is deliberately not free: it costs 28 ms rather than `whoami`'s 6 ms
because it loads and validates the dashboard record in order to make the same
access decision the page makes. A version number leaking to someone who may
not open the dashboard would say that it exists and that its data moved; that
is worth 22 ms. If the poll ever becomes the busiest thing a deployment does,
that is the place to look.

## 6. Configuration

`/etc/gdash/environment`, read by both units:

| variable | default | meaning |
|---|---|---|
| `GDASH_WORKERS` | 1 | see §5; a configured `0` is treated as 1 |
| `GDASH_PORT` | 8780 | |
| `GDASH_ADDRESS` | all interfaces | bind to one interface |
| `GDASH_GBASIC` | `gbasic` on PATH | the interpreter |

### Asking questions in English

`gdash ask <dashboard> "<question>"` needs a model, configured in
`/etc/gdash/models.json`. It is separate from `connections.json` rather than a
section inside it, so a dataset naming a source that does not exist cannot find
a model profile by the same name and try to query it.

```json
{ "default": "house",
  "house": { "provider": "anthropic",
             "model":    "claude-opus-4-1",
             "key_env":  "GDASH_MODEL_KEY",
             "max_tokens": 1024,
             "timeout":  60 } }
```

| key | meaning |
|---|---|
| `provider` | `anthropic` (default), `openai`, `local`, or `offline` |
| `model` | the model name, as the provider spells it |
| `key` | the API key, in this 0600 file |
| `key_env` | **or** the name of an environment variable holding it |
| `base_url` | required for `local`; where the server is |
| `offline_dir` | required for `offline`; see below |

A key may be written in the file or named with `key_env`, which is what a
systemd unit with an `EnvironmentFile` wants. **Neither ever reaches argv, a
dashboard record, the audit log or a rendered page** — a key is read in one
function and never returned.

**`provider: "offline"` checks an install without a model.** It uses the
platform's fixture transport: the reply is whatever
`<offline_dir>/anthropic_response.json` contains, so the whole path — catalog,
prompt, SQL check, requalification, promotion — runs with no key,
no network and nothing spent. It is what gdash's own suite uses.

What comes back is a **draft**, not an answer:

```
$ gdash ask sales "how many orders were over 1000 dollars?"
question: how many orders were over 1000 dollars?

select count(*) as n from orders where amount > 1000

  orders: data as of 2026-09-14 09:12
  regions: data as of 2026-09-14 09:12

  n: 2
```

Money is stored as money, so `amount > 1000` against a USD column means USD
1000, which is what the question asked. Until GDASH-20 gdash stored minor
units and the same query meant ten dollars; the draft then carried a note
restating the literal, which is no longer needed. The model is told which
currency each money column holds. Read the query before you trust the figure:
a draft is a proposal.

`--promote <name>` writes the query into the draft record as a visual, on the
first tab. It edits the draft only; a published dashboard is unchanged until
you `gdash publish`. `--model <profile>` picks a profile other than the
default.

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
at four. An open dashboard is not connected to anything between polls, so the
worst a viewer sees is one poll that does not answer, and the next one does.

## 8. What failure looks like

| symptom | cause | where to look |
|---|---|---|
| pages load, data never changes | the timer is not enabled | `systemctl list-timers gdash*` |
| a dashboard shows "last refresh failed" | the source is unreachable or the query changed | `/var/log/gdash/audit.log` |
| page loads queue at a busy moment | fewer workers than simultaneous page loads | §5 |
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

- **The units are started, stopped, restarted and killed on every opt-in run**
  (`GDASH_SYSTEMD_TEST=1 tests/run_systemd.sh`). This entry used to say the
  opposite, and gave the reason as "there is no systemd in the container used
  for testing" — **which was wrong**: rootless podman boots systemd as PID 1
  given `--systemd=always --cap-add=all`. Verify checks that a unit parses;
  only starting one checks that `ProtectSystem=strict`,
  `CapabilityBoundingSet=`, `User=` and `StateDirectory=` let gdash do its
  work. Starting them found a real defect the first time (G14-1).
- **The install, refresh, publish, serve, backup and restore have all run** at
  real FHS paths as root, in a container, with no `GDASH_*` set.
- **TLS has not been served by gdash**, because it cannot be yet (§6).
