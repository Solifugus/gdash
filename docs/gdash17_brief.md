# GDASH-17 — Operating many tenants

**Status:** built (2026-11-16) and committed locally. Step 0 stopped on
G17-1; the maintainer ruled the two decisions below on 2026-11-16.
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

## Decisions, ruled 2026-11-16

1. **Tenants live under `/var/lib/gdash/tenants` by default** (G17-1). A
   tenant is one directory holding all five roles, so it goes where precious
   state goes: every unit can write there, and the documented backup of
   `/var/lib/gdash` covers it. A base elsewhere takes a `ReadWritePaths=`
   drop-in, documented in operations §6b and tested. The maintainer's other
   multi-tenant applications are to follow the same layout.
2. **An export carries the datasets**, by `gsql.backup`, so a restored or
   moved tenant shows its dashboards at once. `--without-data` leaves them to
   refetch.

## What was built

- **G17-1, G17-2, G17-3 fixed**, and a tenant's directories created 0700.
- `src/gdash_export.bas`:
  - `export_tenant`: pointers first, then `etc/`, `lib/`, `log/`, each
    dataset database through `gdash_store.backup`, and the manifest last.
    Copies and digests are made a 4 MB chunk at a time, so nothing is held
    whole. Everything is 0700/0600;
  - `check_export`: format, stamp format, every path inside a tenant, every
    file's size and SHA-256, and nothing the manifest does not name;
  - `import_tenant`: checked first, built in a hidden directory, renamed into
    place, stamp rewritten, registered last;
  - `purge_tenant`: a whole export of that tenant, suspend, wait for every
    owner, unregister, remove.
- `gdash_tenants`: `write_stamp`, `can_register`, `register`, `read_stamp`
  and `base_of` (moved from `gdash_limits`), `migrate`.
- `gdash_store`: `backup` and `wait_idle`.
- `gdash_audit`: the operator's stream. `gdash_spend` logs each charge;
  `gdash_ask` logs a budget refusal.
- CLI: `tenant export`, `import`, `delete --purge --backup`, `migrate`.
- Tests:
  - `test_export`, 45 assertions: the round trip, tampering, a move to a
    second server's registry, `--without-data`, purge refusals and purge;
  - `test_events`, 21: what is forwarded and what is not, a single root,
    a refresh failure, spend, and every `migrate` status;
  - `run_tenants`: the default base, 0700, and export, import and purge
    from the CLI;
  - `run_systemd`: a tenant under the units and a restore, at the default
    base and (`GDASH_SYSTEMD_TENANT_BASE=/srv/gdash`) with the drop-in.
- Docs: operations §4, §6b, §6d and §10.

## Findings

- **G17-1** (GDASH-15): tenants at the documented `/srv/gdash` could not be
  written under the units. Fixed by the default base and the drop-in.
- **G17-2** (GDASH-16, mine): a slot that could not be written was blamed
  on gBASIC's version. Fixed.
- **G17-3**: a session that could not be stored was a 500 with nothing in
  the journal. Fixed.
- **G17-4** (mine, caught by the round trip): the chunked copy advanced by
  `len(piece)`, which counts characters; on binary data that is fewer than
  the bytes read, so chunks overlapped and each database file grew by a few
  bytes. The digests still agreed, being taken the same wrong way, and the
  imported database read as CORRUPT. It now uses `byte_count`. Not a
  platform defect: `len` is documented as codepoints.
- **G17-5**: a purge deleted a database's directory while a viewer's G-SQL
  owner still lingered on it, and the tenant imported to the same path
  rendered without its data (one run in three under the units). A purge now
  suspends the tenant and waits for every owner to exit first.
- **The single root's spawn check in `run_systemd.sh` was timing-sensitive**:
  started inside the second the publish's fresh data was written, the pass
  found nothing due. It now waits, as the A1 check already did.

## Deliberately not in this phase

- Scheduled or off-site backups: the operator's cron and storage.
- The admin endpoint gcorp would drive (GDASH-18).
- Encrypting an export. It holds credentials, so it is 0700 and the
  operations guide says so, but encryption at rest is the backup store's
  job.
- A purge that also stops the tenant's scheduler timer: gdash does not
  drive systemd. The purge says to, if an owner outlasts the wait.
- Refusing a purge whose export is older than the tenant's last change.
  "Last change" has no single definition here (the audit log changes on
  every sign-in), so the purge requires a whole, verified export of that
  tenant and reports when it was made.
- Rotating `events.log`. It is the base's log directory; logrotate is the
  operator's, as for the audit logs.
