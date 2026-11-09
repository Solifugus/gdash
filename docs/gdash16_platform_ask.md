# Platform ask: what gdash's limits need from gBASIC

**From:** gdash, GDASH-16 step 0 · **Date:** 2026-11-08 · **Build measured:**
`0.10.0+ad6b7f3d`

GDASH-16 puts limits on what one tenant can consume: disk, concurrent
refreshes, dataset size, and model spend. Two of them work today. One waits on
`lock(f, { wait: false })`, which is already in gbasic's 0.11.0 batch. The
three asks below are what stands between the other limits and the numbers
they are supposed to keep. They are in priority order.

## B1. A memory limit on a child process. **Done: gbasic `decd684b`**, used by every refresh child

**Need.** `process.start({ command, args, limits: { memory: <bytes> } })`,
setting `RLIMIT_AS` (or `RLIMIT_DATA`) in the child before `exec`. A child
that exceeds it should fail its allocation and exit, and the handle's status
should say so, ideally with something distinguishable such as a `limit` field
or a documented exit code.

**Why.** A refresh child holds its whole result set in memory. Measured at 10
columns it costs about **3 KB a row (about 300 bytes a cell)**: 68 MB at 10,000
rows and 191 MB at 50,000. A tenant's query that returns ten million rows
grows until the kernel's OOM killer chooses a process. Under systemd that
happens inside the server's cgroup, and the process it kills need not be the
child. gdash can count cells once a fetch returns. Only a limit set before
`exec` stops the fetch that never returns.

**Today.** gdash checks the cell count after the fetch and refuses to swap
above the ceiling. That refuses a dataset that fits in memory but is over the
ceiling. It does not protect against one that does not fit.

## B2. A row cap on a source query that does not buffer past it. **Done: gbasic `decd684b`**, used by the Postgres and ODBC sources

**Need.** `pg.query(conn, sql, params, { max_rows: N })`, and the same on
`odbc`, using libpq's single-row mode (or a cursor) so that no more than N+1
rows are ever held. On the (N+1)th row it should stop, and either raise a
documented code or answer with a `truncated: true` marker. Raising is
preferable, because then a refresh cannot quietly keep a partial result.

**Why.** It turns B1's backstop into a refusal that names the problem: "this
query returned more than 200,000 rows; the ceiling is 200,000". A memory
limit can only say "the refresh ran out of memory". gdash could wrap the SQL
in `select * from (...) limit N+1`. That works on Postgres and is wrong on
SQL Server, and the dialect is the source's, not gdash's.

## B3. A swapped-out table's space, and a reading of a database's size. **Tables done: gbasic `ac37c5a3`.** The logs (about 40 MB per idle database) wait on the maintainer's ruling; gdash prefers flushing and truncating at close

**Measured.** Twelve swaps of the same 20,000-row table (drop `live`, rename
`s` to `live`, one transaction, each `s` written by `gsql.insert` in
1,000-row calls). The live data is about 5.5 MB of `.sst`. The directory
measured:

| swap | 1 | 2 | 3 | 4 | 6 | 8 | 10 | 11 | 12 |
|---|---|---|---|---|---|---|---|---|---|
| MB | 9.9 | 17.8 | 35.9 | 47.1 | 70.7 | 81.9 | 89.7 | 46.0 | 47.4 |

After a reopen and one more swap the directory was 65.8 MB, and two 20 MB
`db.log.N` files were always present. `gsql_storage_design.md` §5 says a
replaced dataset's files "are now dropped whole". At this size the dropped
table is evidently still in the logs and the unmerged levels until a
compaction reaches it.

**Why it matters.** gdash's disk quota counts what is on the volume, because
filling the volume is what a quota prevents. When a dashboard is refreshed
every few minutes, its usage swings between 2x and 16x its data. A quota set
at "a few times what this tenant stores" would then refuse refreshes for a
tenant whose data is not growing.

**Need, either of:**
- a dropped or swapped-out table's space returned at (or soon after) the
  commit that drops it, so the directory stays within a small, stated multiple
  of the live data; or
- `gsql.space(path)` → `{ live_bytes, total_bytes }`, so the quota can be set
  on a stable number, with a documented bound on how far `total_bytes` can
  run ahead of it.

The first is better for everyone who meters disk. The second lets gdash state
the quota honestly in the meantime.

## Already coming

- **`lock(f, { wait: false })`** (0.11.0 batch). gdash's refresh slots, global
  and per tenant, are built on it. Each is a set of slot files, and a refresh
  takes the first free one or is deferred. Nothing else is needed.
