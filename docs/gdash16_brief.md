# GDASH-16 — Limits

**Status:** built (2026-11-08). The refresh tests are waiting on gBASIC
0.11.0 being installed (see "Blocked").
**Authority:** `gdash_design.md` outranks this brief. What it implements is
`gdash_saas_design.md` §6 (the `access: open` gate) and §7 (limits).

## Why this phase exists

GDASH-15 made a tenant a root. Nothing yet stopped one root from filling the
volume, running unbounded refreshes, holding a result set larger than the
machine, spending money on questions, or publishing to the internet by
editing one line of a record. "A limit added after the first incident is a
limit that was needed before it."

The tenant-level gate on `access: open` was listed under GDASH-17. It was
taken first here, as proposed at the end of GDASH-15, because it is the one
that must exist before any real tenant is onboarded.

## Step 0 — measured before designing

- **Refresh child memory: about 300 bytes a cell at its peak.** Fetching
  from Postgres, planning and materializing ten-column rows measured 40.7 MB
  for 1,000 rows, 68.6 MB for 10,000 and 191.5 MB for 50,000. That is about
  3 KB a row once the interpreter's baseline is subtracted. So the ceiling is
  counted in **cells**. Its default is 1,000,000 cells, about 300 MB a child.
  (`tests/measure/refresh_memory.bas`.)
- **The fetch was quadratic (G16-1, fixed).** The Postgres source built rows
  with `concat`, which copies the whole array for each row. 50,000 rows took
  90 s to fetch; with `append` it takes 15.9 s. The ODBC source already used
  `append`.
- **G-SQL does not give back a swapped-out table's space promptly (G16-2,
  ask B3).** Twelve swaps of a 5.5 MB table took its directory from 9.9 to
  89.7 MB, down to 46 MB once compaction caught up, and 65.8 MB after a
  reopen. The quota counts the volume, so the operations guide says to set it
  with that headroom. gbasic treats this as a defect against
  `gsql_storage_design` §5.
- **Walking a root's disk use is free at this scale:** 0.1 ms over a
  database directory. It is done on every refresh, twice.
- **Model usage is reported.** `llm.chat` returns `usage: {input, output}`,
  so the meter needs nothing from the platform. `llm.ask` discards it, so
  gdash's wire now calls `chat`.
- **A non-blocking lock exists only from gBASIC 0.11.0.** Version
  `0.10.0+ad6b7f3d`, the one installed, raises on `lock(f, { wait: false })`.
  It is in gbasic's current batch.

## Decisions made in building it

- **The limits are found from the root, not handed down.** A tenant's stamp,
  `etc/tenant.json`, now names its registry. `gdash_limits.for_root(p)` reads
  the stamp, finds the registry, and checks that the registry places that
  tenant at this directory. Every entry point gets the same answer from `p`
  alone: a request, the scheduler, `--tenant`, and an operator's bare
  `--root`. Plumbing the limits down from `tenant_of` would have left the
  bare `--root` path unlimited.
- **Fail closed, to the most restrictive answer.** These give no open
  access, no refresh and no questions:
  - a `limits.json` that does not read;
  - a bad value in a tenant's limits;
  - an unreadable stamp;
  - a stamp whose registry does not list the tenant, or places it elsewhere,
    as with a copied tenant directory.

  The defaults are given only when nothing is wrong.
- **The operator's places only.** Defaults and the server-wide cap live in
  the base's `etc/limits.json`, and one tenant's overrides in its registry
  entry. A tenant's own `etc/` holds no limit, because a limit a tenant could
  edit is not one.
- **A single root keeps today's behaviour,** with `access: open` the
  per-dashboard opt-in, no quota and no budget. It does get the dataset
  ceiling and the refresh cap, which protect the machine rather than the
  bill.
- **`access: open` where open is not permitted is simply not open.** The
  record falls through to the group rules, so it becomes an admins-only
  dashboard rather than a broken one. Publishing such a record is refused
  with the reason and what to do instead. The view-time check is the one
  relied on, since a record can be edited on disk; the publish refusal is
  what tells the author.
- **A full slot set defers; it does not fail.** No state is written, so the
  dataset is not backed off and is not reported as failing, and the next
  pass runs it. An interpreter without the non-blocking lock is a failure
  that names the lock, not a deferral. Reporting "the server is full" then
  would send an operator looking for refreshes that do not exist.
- **The quota is checked twice:** once before the fetch (already over:
  fetch nothing) and once before the swap (the new data, staged beside the
  old, would take the root over). The old data is served either way, by the
  stale-but-coherent rule. A publish that carries data is checked too; one
  that carries none, such as a title change, never is.
- **The ceiling is checked in the child, before anything is written.** So a
  refused dataset leaves no staging table.
- **The budget is checked, then charged.** It is checked before the model is
  called, so a refusal costs nothing. It is charged after the call with the
  reported tokens, or an estimate set high when none are reported. A reply
  that turned out unusable is still charged, because it was still paid for.
  Concurrent questions can overshoot by at most one each; reserving the
  worst case first would refuse questions that fit.
- **A tenant has no budget until the operator sets one,** so its questions
  are off by default.
- **Under a budget, a profile with no price is refused.** A price in another
  currency than the budget is refused too, because there is no exchange
  rate here.

## What was built

- `src/gdash_limits.bas`:
  - finding a root's limits (`for_root`) and validating them;
  - `limits.json`;
  - `tenant limit` parsing;
  - disk use and the quota check;
  - the refresh slots.
- `src/gdash_spend.bas`: prices, the monthly ledger under a lock, cost and
  estimate, and the budget check.
- `gdash_refresh`:
  - the quota before the fetch and before the swap;
  - slots taken around the child and released on every path;
  - `deferred` in `run` and in the pass's counts;
  - `max_cells` in the job.
- `gdash_refresh_child`: refuses above the ceiling and exits 7.
- `gdash_app.allowed(rec, v, need, open_ok)`, used by both the page and the
  index.
- `gdash_publish`: refuses `access: open` where it is not permitted, and
  refuses a data-carrying publish over quota.
- `gdash_ask`: the budget gate and the charge. The wire returns `usage`.
- CLI:
  - `tenant limits <id>` shows the effective limits, disk use and the
    month's spend;
  - `tenant limit <id> <name> <value>`;
  - `schedule` prints deferrals.
- Tests:
  - `test_limits`: 54 assertions;
  - `test_limits_refresh`: the ceiling, both quota checks, tenant and server
    slots held from another process, and release;
  - `test_ask`: the budget through the pipeline, including that the model
    is never called once the budget is spent;
  - `test_app`: the gate;
  - `run_tenants`: the gate end to end, before and after it is granted, and
    the publish refusal.
- Docs:
  - operations §6c;
  - the minimum gBASIC is now 0.11.0;
  - platform ask `gdash16_platform_ask.md` (B1–B3).

## Blocked

- **gBASIC 0.11.0, for `lock(f, { wait: false })`.** Every refresh takes a
  slot, so on 0.10.0 every refresh fails and names the missing lock. So
  `test_limits_refresh`, `test_carry`, `test_refresh` and every runner that
  refreshes are waiting for that install. `test_limits`, `test_ask`,
  `test_app` and `test_tenants` pass on 0.10.0.

## Findings

- **G16-1:** the Postgres source's fetch was quadratic. Fixed.
- **G16-2:** G-SQL's space after a swap, 2–16x the live data. gBASIC ask B3.
- **G16-3:** `plan_columns` infers a kind by scanning every cell of every
  undeclared column. That is most of the write phase's time apart from the
  insert itself. Not fixed here; it is the next cost to take out of a large
  refresh.
- **G16-4:** `number("lots")` raises rather than answering unknown. Guarded
  where parsing a limit.

## Deliberately not built

- **A memory limit on the refresh child** (ask B1), and **a row cap that
  stops the fetch** (ask B2). Until these land, a query too large to return
  at all is not stopped; only one that returns and is over the ceiling is
  refused.
- **Reserving a question's worst-case cost** before calling the model.
- **The operator-side event stream** (GDASH-17). Deferrals, quota refusals
  and budget refusals are in each tenant's audit log, and nowhere central.
- **Design-document edits.** `gdash_design.md` §8 says `access: open` is a
  per-dashboard opt-in. It would need a sentence saying that in a
  multi-tenant deployment the operator must permit it per tenant, and §3
  would need the refresh-concurrency limit. Both are the maintainer's to
  make.
