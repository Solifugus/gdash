# GDASH-17 — Operating many tenants

**Status:** step 0 run (2026-11-15). **Stopped on G17-1**, which a decision
is needed for before building.
**Authority:** `gdash_design.md` outranks this brief. What it implements is
the GDASH-17 entry in `gdash_development_plan.md`, and
`gdash_saas_design.md` §5 (the format stamp) and §6 (the operator-side
event stream; "downtime is acceptable, data loss is not").

## Why this phase exists

GDASH-15 made a tenant a root and GDASH-16 bounded what one may consume.
Nothing yet lets an operator do the things that running other people's data
obliges:
- back a tenant up, and **restore it, tested**;
- move one between servers;
- delete one cleanly;
- see across tenants what has gone wrong.

The first real deployment is expected to be gcorp's own site, followed by
beta customers.

## Scope

- `gdash tenant export <id> <dir>` and `gdash tenant import <dir>`. Backup,
  moving between servers and deletion are the same directory operation.
- A **tested** restore, at real FHS paths under the real systemd units,
  extending `run_systemd.sh` rather than duplicating it.
- An operator-side event stream: sign-ins, refresh failures, refusals,
  spend, one line per event and tenant, in the base deployment's log.
- `gdash tenant migrate --all`, reading each tenant's format stamp.

## Step 0 — measured before designing

- **A dataset database can be copied consistently while in use.**
  `gsql.backup` copied a 20,000-row dataset in 3.1 ms while a second
  connection held the database open. A rewrite of the live table afterwards
  left the copy at 20,000 rows. Backing up again into the same copy reused
  its two data files and wrote 1.4 KB. (`tests/measure/backup_probe.bas`.)
- **A tenant's other files can be copied live, in one order.** Snapshots
  are never deleted, and a `current` pointer is renamed into place only
  after its snapshot is written. So copying the pointers **first** and
  everything else after gives a copy in which every pointer names a
  snapshot that is there. Every other file gdash rewrites is written to a
  temporary file and renamed. The audit log is append-only, so a copy is a
  prefix of it.
- **`zip` is not the container.** `zip.write` builds its archive from
  members held in memory, and refuses anything past 4 GB (no ZIP64). A
  tenant's default quota is 1 GiB and may be raised. An export is therefore
  a **directory**, which an operator can `tar`, `rsync` or `scp`.
- **G17-1: tenants under the documented base do not work under the
  systemd units.** Measured in `run_systemd.sh`'s container, with the
  tenant at `/srv/gdash/acme` as operations §6b shows:
  - the per-tenant scheduler unit failed every refresh;
  - the server answered the tenant's sign-in page with 500;
  - an `access: open` page still rendered, because it writes nothing.

  Every write was refused as "Read-only file system". The units run under
  `ProtectSystem=strict`, which leaves only their `*Directory=` paths
  writable, and `/srv/gdash` is not one. GDASH-15 tested tenants only with
  `--root` and never under the units, so this was never seen.
- **G17-2: a slot that cannot be written is blamed on gBASIC's version.**
  The refusal said "this gBASIC has no lock(f, { wait: false }) (0.11.0 or
  later is required)", for a read-only file system. Every build gdash now
  accepts has that lock, so any raise there is the file's own error and
  should be reported as such. (My own GDASH-16 code.)
- **G17-3: a session that cannot be created is a 500 that logs nothing.**
  `gdash_app` returns "could not start a session" without the cause, and
  the server's journal had no entry at all for the request.
- **A tenant's directories are created 0755.** Its credential files are
  restricted one by one (0600), but `etc/`, `lib/` and `log/` can be listed
  by any local user. For data held on behalf of other organisations, 0700
  is the right default. G-SQL already creates its own directories 0700.

## Decisions needed

1. **Where tenants live under systemd (G17-1).** Recommended: the base
   defaults to `/var/lib/gdash/tenants`, which every unit can already write.
   The existing `tar` of `/var/lib/gdash` then backs tenants up too. A base
   anywhere else, such as a separate volume at `/srv/gdash`, takes a
   drop-in adding `ReadWritePaths=` to `gdash.service` and
   `gdash-scheduler@.service`, documented and tested. The alternative is to
   put `ReadWritePaths=-/srv/gdash` in the shipped units, which works only
   for that one path.
2. **Whether an export carries the datasets.** Recommended: yes, through
   `gsql.backup`. A restored or moved tenant then shows its dashboards at
   once, without depending on its sources being reachable from the new
   server, and the measured cost is small. `--without-data` leaves them to
   refetch, which is what a single root's backup does today.

## Proposed, once those are ruled

- **G17-1, G17-2 and G17-3 fixed first**, and tenant directories made 0700.
- `tenant export <id> <dir>`, which runs live:
  - pointers first, then `etc/`, `lib/` and `log/`;
  - each dataset database through `gdash_store`, by `gsql.backup`;
  - never `run/`, which holds only sessions and counters;
  - a `manifest.json` last: format, tenant, gdash and gBASIC versions, and
    every file with its size and SHA-256;
  - the export directory 0700, because it holds the tenant's credentials.
- `tenant import <dir> [--as <id>] [--host <host>]`:
  - checks the manifest before writing anything;
  - refuses a format newer than this build reads;
  - places the tenant at `<base>/<id>` and rewrites its stamp for this
    server's registry;
  - writes the registry entry **last**, the order `tenant create` already
    uses, so a half-imported tenant is unreachable rather than half-open.
- `tenant delete <id> --purge`, which removes the directory after the
  entry. It refuses unless an export of that tenant made since its last
  change is named.
- The event stream: `<base log>/events.log`, one JSON line per event,
  carrying the tenant id. It covers sign-ins (ok, failed, throttled),
  refresh failures and deferrals, quota, reserve and budget refusals, and
  each question's charge. It is written beside the tenant's own audit line,
  best-effort like the audit log, and never carries a credential.
- `tenant migrate --all | <id>`: reads each stamp and reports it current,
  newer than this build (refused), or unreadable. It applies the steps
  between, of which there are none today: format 1 is the only one.
- Tests:
  - an export and import round trip in the hermetic suite;
  - a restore under the real units in `run_systemd.sh`: export, destroy,
    import, and the tenant serves and refreshes again.

## Deliberately not in this phase

- Scheduled or off-site backups: the operator's cron and storage.
- The admin endpoint gcorp would drive (GDASH-18).
- Encrypting an export. It holds credentials, so it is 0700 and the
  operations guide says so, but encryption at rest is the backup store's
  job.
