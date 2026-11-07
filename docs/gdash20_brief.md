# GDASH-20 — The staging store on G-SQL

**Status:** **built, at the review boundary** (2026-11-06). Step 0 stopped on
S0-6, the owner's socket under the systemd units. The maintainer's
instruction, through the gbasic session, was to build without waiting for the
fix, which gbasic has taken as A1. The DONE note is at the end of this brief,
and the findings are in `gdash20_findings.md`.
**Authority:** `gdash_design.md` outranks this brief. Where this phase changes
the design, the edits are listed in §6 of the plan and are made as rulings,
not silently.
**Plan:** `gsql_migration_plan.md` is this phase's plan, with every decision
ruled (D1–D5, D4a). This brief does not repeat it. It records step 0 and the
order of work.

## Why this phase exists

G-SQL is gBASIC's own database. Its values are gBASIC values, so money and
integers above 2^53 cross no boundary. It gives gdash what SQLite made it build
by hand: an atomic swap under live readers, engine-enforced read-only
transactions, and no cap on how many datasets a query can reach. Moving the
staging store onto it deletes `to_minor`, the attach machinery and the `__text`
casts, and removes the 11-dataset limit.

## Step 0

### S0-0 — the suite was red before the phase started, and is green again (f8fd8b5)

On the current build, 14 of 37 suites failed. The cause was gbasic `4f3eb1e`
(2026-10-24), which made `=` and `!=` propagate `unknown`. gdash compared
absent record fields as if that answered `false`, and an `if` on `unknown`
raises. Every failure was a raise, never a wrong branch. Each site now keeps
its old meaning through `default(x, <absent value>)`, so access and admin still
fail closed. This was done before the phase because no phase work can be
verified on a red suite. It changes no behaviour, and it is its own commit.

The one that mattered: the identity's `admin` flag was built as `admin = true`
and would have been `unknown` for a user record with no `admin` key.

### S0-1 — platform version: passes

`gbasic --version` reports `0.10.0+cac666c`, which includes `e902acf` (S1–S3,
trimmed integer text, numeric text into `number`). PCRE2 10.46 is installed.

**Note:** the gbasic session was compiling on this machine during step 0. The
suite's platform stamp catches a binary swapped mid-run. A run that fails with
no useful output should be re-run before it is debugged.

### S0-2 — the corpus on G-SQL: passes

All 10 visual and ask statements run unchanged against tables loaded from the
reference fixtures. The ask statements needed `orders.orders` → `orders`,
which is D1's layout. One answer **changes meaning, as intended**:
`ask.canned.2`, `amount > 1000`, now counts orders over USD 1000 (2 rows), not
over 1000 cents. The e2e "cents question" assertions change with it.

The 5 dataset statements run on the source and do not change. The 14
store-internal statements are replaced by the rewrite.

### S0-3 — nlq with tables that have no schema: passes, by reading

`nlq._id(schema, name)` returns the bare name when the schema is empty, and
every catalog lookup goes through it. Execution confirms this in step 6 of the
work, through `test_ask` and `test_nlq`.

### S0-4 — rendering money at a column's scale: passes

`money.text(m, n)` renders at `n` places, half-even, and `money.text(m)`
round-trips. Measured 2026-11-03 (plan §2).

### S0-5 — the owner under a `--root` temp dir: passes, with a runner change

- **Where its files go.** The owner runs as `gbasic --gsql-owner --linger=N
  <path> …`, with the path as the client gave it. Its data lives in the
  database directory, under the root. Its socket goes in
  `$XDG_RUNTIME_DIR/gbasic` (or `/tmp/gbasic-<uid>`), which is **outside** the
  root. Spill files go in `$TMPDIR` (or `/var/tmp`). Each is removed by the
  process that made it.
- **The owner outlives its last client.** After a 10⁶-row load with
  `linger: 0`, the database directory could not be removed the moment the
  program exited: the owner was still writing a sorted file. It could be
  removed a moment later.
- **The consequence:** scratch-clean must first wait, with a bound, for owners
  whose argv names a path under the scratch root, and fail if any remain. gdash
  always connects by absolute path, so the match is exact, and the runner never
  signals a process it did not start. This is the same discipline as `e5b1a39`.

### S0-6 — the owner under the systemd units: **fails, by analysis**

Every gdash process that touches one dashboard's database must reach the same
owner. Those processes are the server's workers, the scheduler's refresh pass
and its children, and an administrator's CLI. A client finds the owner through
a socket in `$XDG_RUNTIME_DIR/gbasic`, or in `/tmp/gbasic-<uid>` when that is
unset (gbasic `src/gsql/owner.c:86`). Both of these break under the units:

- **System services have no `XDG_RUNTIME_DIR`**, so each falls back to
  `/tmp/gbasic-<uid>`.
- **Both units set `PrivateTmp=true`**, so `gdash.service` and
  `gdash-scheduler.service` each see their own `/tmp`. The scheduler's refresh
  would not find the server's owner. Its new owner would lose the database's
  lock, and its client would retry a socket it cannot see until it gave up. So
  **a refresh fails whenever anyone has the dashboard open**. An
  administrator's `gdash refresh` has the same problem from a third `/tmp`.

This was not measured by starting the units (`run_systemd.sh`). The failure
needs the migrated build, and the reasoning rests on two facts that were each
read directly: the code that picks the socket directory, and `PrivateTmp`.
`run_systemd.sh` runs before the phase closes.

**Not designed around.** The only remedy available today is to set
`XDG_RUNTIME_DIR=/run/gdash` in both units and in the CLI wrapper. That puts a
path outside the resolver, changes the variable for every other XDG consumer in
those processes, and still misses an administrator who runs the interpreter
directly. The platform ask proposes the database finding its own owner
instead.

### S0-7 — refresh at volume: measured

Staging inserts go through the owner, 1 000 rows a transaction, with one row
per statement:

| rows | time | client peak RSS | on disk |
|---|---|---|---|
| 10⁴ | 0.39 s | 31 MB | — |
| 10⁵ | 3.7 s | 31 MB | — |
| 10⁶ | 48 s | 32 MB | 96 MB |

At 10⁵ rows, 10 rows per statement **halves** the time (1.8 s), so the refresh
child batches its statements. 100 rows per statement measured slower, which is
probably this probe building its argument array with `concat`; the child
builds with `append`. The client's memory does not grow with the load, so
G-SQL's side of bounded-memory refresh is ready. gdash's source seam still
holds every row (plan §5, deliberately not in this phase).

This is the refresh-duration figure `platform_answer_gsql_volumes.md` §3 said
was owed: at 10⁶ rows the staging write is about 20–50 s, on top of the source
query.

## The work, once S0-6 is answered

The order in plan §5, steps 1–9. Two additions came out of step 0:

- the runner's scratch-clean waits for owners serving the scratch root
  (S0-5);
- the store's `connect` passes whatever the platform answer to S0-6 provides.
  It is one function in `gdash_store`, and every other process reaches the
  database through it.

## Deliberately not built

These are listed in plan §5: bounded-memory refresh, carrying draft data over
on publish (G11-11), dataset sharing, and tenancy work beyond the
tenant-rooted layout.

## DONE note (2026-11-06)

**Built.** The staging store is G-SQL:

- **Layout:** one database per (dashboard, stage), at
  `<cache>/<dashboard>/<stage>/data.gsql`. Every dataset is a table in it.
- **Refresh:** writes `<dataset>__staging`, ten rows a statement and a
  thousand rows a transaction. The parent swaps it in one transaction (drop
  the live table, rename the staging one, move its `_gdash_meta` rows). The
  version bump comes after.
- **Reads:** every read runs in `begin("read")`, so a write is refused at the
  engine.
- **Money:** stored as `money(<currency>)`, exactly. `scale` is the display
  scale, rendered half-even by `money.text` (D4a). A money value renders in
  its own currency, and a stated currency that disagrees is refused.
- **Params:** may declare a `type` and are converted on arrival. One that does
  not convert is a 400 naming it (D3).
- **Ask:** the catalog names tables bare. The model is told each money
  column's currency. The minor-unit notes and the literal-restating guard are
  gone, because `amount > 1000` now means USD 1000.
- **Deleted:**
  - `to_minor`'s conversion and its excess-decimal check;
  - every attach, `_ro_uri`, `_connect_across` and `attach_limit`;
  - the 11-dataset rule;
  - the `__text` casts and `exact_columns`;
  - the schema-qualified meta reads;
  - `load sqlite`.
- **Kept, as a stopgap:** the rule that trailing zeros are not precision
  (G20-3, ask A6).
- **Suite infrastructure:** the suite runs with `GDASH_GSQL_LINGER=0`.
  Scratch-clean waits, by path, for owners serving the scratch root
  (`tests/gsql_owners.sh`). `tests/stage_query.bas` and
  `tests/staging_probe.bas` let the shell runners read the store.

**Measured green, on `0.10.0+db72b76`:**

- the hermetic suite, 37 of 37;
- the ODBC runner, 12 of 12;
- live Postgres, 10 of 10;
- the systemd suite under podman, including a new probe that reproduces A1.
  It measures a 28.5 s refresh stall, where step 0 had predicted an outright
  failure (G20-2).

**Deliberately not built:**

- bounded-memory refresh;
- publish carrying draft data across (G11-11);
- dataset sharing;
- relaxing the scale-conflict refusal (G20-9, a ruling owed);
- any workaround for A1. The units' `PrivateTmp` stays, and so does the stall,
  until the platform's socket-in-the-database lands.

**Owed to the maintainer:**

- the design edits, written out as G20-a to G20-g in
  `gdash_design_edits_owed.md`. The CLAUDE.md invariants are among them;
- the G20-9 ruling;
- relaying A5 and A6 to gbasic (A1 to A4 are already there).
