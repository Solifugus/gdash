# GDASH-2 — Refresh engine: phase brief

**Status:** IN PROGRESS.
**Narrows:** the GDASH-2 paragraph of `gdash_development_plan.md`.
**Authority:** `gdash_design.md` outranks this brief. The findings of GDASH-0
(`gdash0_findings.md`) and GDASH-1 (`gdash1_findings.md`) are inputs, not open
questions.

GDASH-0 proved one manual refresh end to end. GDASH-1 made the record format
mean what it promises. GDASH-2 turns one manual refresh into the real thing:
data that arrives without anyone asking, from more than one source, with
failures that are visible instead of silent.

---

## 1. Step-0 verification

Eight premises decide this phase's shape. All checked against gBASIC `0d83ffb`
(0.1.0-rc9 in development).

- **V1 — a server-side timer: FAILS.** The plan says "per-dataset scheduling
  off the server's timer." There is no such timer. The `server` block admits
  exactly one hook — `src/frontend.c:373` refuses anything else with
  *"unknown hook 'on %s' (only 'on drain' exists)"* — and `main` **must
  return** for the event loop to run at all; looping after `serve` binds the
  listener and hangs every request. So the premise is not there, and the
  phase's shape changes rather than the premise being designed around: see
  §2.2. Verified further, and decisively: with `workers: 2`, **`main` runs
  three times** (supervisor plus two workers). A scheduler spawned from `main`
  would therefore be spawned once per worker plus one — five copies on a
  four-worker deployment, each racing the others to refresh the same dataset.
- **V2 — SQLite ATTACH: PASSES**, and better than hoped.
  `sqlite.exec(db, "attach database 'b.db' as regions")` works, the
  parameterized form works, and a cross-file join returns correct rows.
  Crucially, **unqualified table names resolve across attached schemas**: with
  `regions.db` attached as `regions`, a visual query says `join regions r`,
  not `join regions.regions r`. Multi-dataset queries therefore read exactly
  like single-dataset ones.
- **V3 — the attach limit is real: 10.** The eleventh attach fails with
  *"too many attached databases - max 10"*. A dashboard is therefore capped at
  **11 datasets** (one open as `main`, ten attached), and that cap is a
  load-time refusal with its own golden, not a runtime surprise.
- **V4 — ambiguous table names resolve silently to `main`**, with no error.
  Each dataset file holds its data table plus `_gdash_meta`, so `_gdash_meta`
  is present in *every* attached file and any unqualified read of it would
  quietly answer from whichever file is `main`. Every metadata read must be
  schema-qualified. This is a correctness requirement, not a style note.
- **V5 — content hashing: PASSES**, with a trap. `sha256()` is a builtin but
  returns **raw bytes**: `len()` on a digest under-reported for 138 of 200
  probe digests, because the bytes are not valid UTF-8 and `len` counts
  characters (`byte_count` correctly says 32). Use `crypto.sha256_hex`. The
  raw form is not wrong, it is just not a string you may measure.
- **V6 — appending to a log: PASSES.** `append(f, text)` is whole-file append,
  which is what an audit log wants.
- **V7 — a non-blocking advisory lock: ABSENT.** `lock(f)` is
  `flock(fd, LOCK_EX)` with no `LOCK_NB` (`src/eval.c:4387`), so there is no
  way to ask "is someone else refreshing this?" without waiting for the
  answer. Consequence in §2.6.
- **V8 — the suite still passes on current gBASIC.** 12 suites, 0 failed;
  e2e 31/31; live Postgres 5/5. The rc9 change to `list`/`files`/`folders`
  (plain string paths) did not disturb the resolver.

Two smaller observations recorded rather than acted on: `file_type(p)` is
**new and useful** — `"file"` / `"folder"` without raising, on a plain string —
but `docs/reference.md:4120` says a missing path answers `"missing"` and it
actually answers `unknown`. And `sqlite.columns` is **still absent**; GDASH-1
already ruled the first-refresh fallback, and nothing here reopens it.

## 2. Scope — the narrowing

### 2.1 Refresh policies

`manual` (shipped), plus **`on_open`** and **`interval`**. The `refresh` key
stays a **string** — `format: 1` is a published contract and GDASH-1
documented it as one — and gains sibling keys rather than becoming a record:

- `"refresh": "interval", "every": 300` — seconds. `every` is required for
  `interval` and refused elsewhere.
- `"refresh": "on_open"` — a page open *requests* a refresh; optional
  `"min_age": N` suppresses the request when the data is younger than N
  seconds.

**`on_open` requests; it does not fetch.** The whole point of the two-tier
model (design §3) is that the expensive fetch stays off the request path, and
an inline fetch in a page handler pins a worker for exactly as long as the
source is slow. So `on_open` writes a request into the dataset's state and
returns; the page renders the data it has, with its "data as of"; the
scheduler performs the fetch; SSE tells the open tabs when it lands. A
dashboard opened by twenty people files **one** request, because a request
already pending is not duplicated — which is also why `min_age` needs no
invented default.

The cost, stated plainly: with no scheduler running, `on_open` and `interval`
do nothing at all, and the dashboard serves stale data forever. That is the
stale-but-coherent posture rather than a new failure mode, and §2.7 makes it
visible instead of silent.

### 2.2 The scheduler is a separate program

V1 leaves one honest shape:

- **`src/gdash_sched.bas`** — the decision, as a pure function. Given a
  dataset's policy, its state and a clock reading, is it due? No I/O, no
  sleeping, and therefore testable without waiting for real time to pass.
- **`gdash_cli schedule --once`** — one pass over every published dashboard:
  decide, refresh what is due, write state. This is the whole engine, and it
  is what the hermetic suite drives.
- **`src/gdash_scheduler.bas`** — a program that calls that pass on a period.
  It owns nothing the `--once` pass does not; it is a loop and a `sleep`.

The server does **not** spawn it (V1: it would spawn N+1 of them) and does not
supervise it. Operators run it as a second unit; GDASH-7 owns that unit file,
and until then the e2e runner starts it the way an operator would. This costs
a process and buys a scheduler that cannot be multiplied by a worker-count
change, cannot pin a request worker, and can be tested a tick at a time.

### 2.3 Multiple datasets, and ATTACH

A dashboard may name up to eleven datasets (V3). A visual names its primary
`dataset`; the store opens that file as `main` and **attaches every sibling
dataset of the same dashboard that exists on disk**, each under its own name.
By V2 the query then reads `from orders join regions` with no qualification —
one namespace, exactly as if the datasets were tables in one database.

- A sibling that has never refreshed is simply not attached; a query naming it
  fails with SQLite's own message, surfaced per-visual as GDASH-0 already does.
- `_gdash_meta` is read **schema-qualified**, always (V4).
- Params still appear only in visual queries (design §2). Attaching changes
  nothing about that and validation still enforces it.

### 2.4 Draft and published data directories

Design §3: *draft datasets refresh manually only; published datasets follow
their policy.* That rule needs two data directories and a way to tell which
one applies, so `data_dir` gains a mode and every dataset path with it:
`<cache>/<name>/draft/` and `<cache>/<name>/published/`.

Enforcement lives at the single refresh entry point: a non-manual trigger
against a draft dataset is refused by name, not ignored. The scheduler only
ever asks for published.

**One forward reach, deliberate and named.** Deciding what is published means
reading `dashboards/<name>/current`, which design §7 specifies and GDASH-3
owns. GDASH-2 implements the **read** side only — one function, resolving
`current` to `snapshots/NNNN.json` — because without it the scheduler has
nothing to schedule and the whole deliverable is untestable. GDASH-3 owns
every write: publish, rollback, session pinning, diff, audit. If GDASH-3 rules
the pointer differently, one function changes.

### 2.5 Per-dataset state, and failure surfacing

A dataset gets a state file beside its data: last attempt, last success, last
error, row count, content hash, and any pending refresh request. From it:

- **"data as of" becomes per-dataset** rather than one line taken from the
  first dataset's mtime, which is what the current page does and what stops
  being true the moment there are two datasets.
- **A failed refresh is visible on the dashboard** — which dataset, when, and
  what the source said — instead of being a line on a terminal nobody is
  watching. The visuals keep rendering the old data. Stale-but-coherent is
  only a virtue if the viewer is told the data is stale.
- **Audit events are appended as JSONL** to `<log>/audit.log` (design §6):
  refresh attempted, succeeded, failed, and skipped-as-unchanged. One object
  per line, greppable, with no credentials in any field.

### 2.6 Concurrency between refreshers

Two schedulers, or a scheduler and a manual refresh, can target one dataset at
once. V7 says there is no non-blocking lock, so: a per-dataset lock file, a
**blocking** `with lock`, and — this is the part that matters — a **re-read of
the state after acquiring it**. A policy-driven refresh that finds the dataset
was refreshed while it waited stands down; a manual refresh always proceeds,
because a human asked. Serialization comes from the lock, and the wasted
duplicate fetch is removed by the recheck rather than by a lock we cannot have.

### 2.7 Staging sweep, and content-hash dedupe

- **Sweep.** A crashed child leaves `<dataset>__staging.db`. GDASH-0 cleared
  residue it had observed; residue from a crash is swept here, at scheduler
  start and on every pass, with an audit line — silently deleting files is how
  a sweep becomes indistinguishable from data loss.
- **Dedupe, the half that earns it.** The plan says content-hash dedupe "if it
  proves worth it". The half that does: hash the fetched result and, when it
  equals the current one, **skip the swap and the version bump**. Every open
  tab reloads on a version bump, so an unchanged five-minute refresh currently
  reloads every viewer's dashboard twelve times an hour to show them the same
  numbers. That is worth a hash.
- **Dedupe, the half that does not.** Sharing fetch work *between dashboards*
  needs a cross-dashboard registry keyed on (profile, SQL), and dataset
  sharing is deferred by name in design §10. Deferred with it, and recorded.

## 3. Construction rules

Unchanged from GDASH-0 §4 and GDASH-1 §3, and additionally:

- **The decision is pure; the clock is an argument.** A hermetic suite may not
  wait five minutes to see an interval elapse, and a test that sleeps to
  observe scheduling is testing `sleep`. Every due-decision takes `now` as a
  parameter.
- **`gdash_store` hardens.** The plan says the module boundary hardens here:
  attach, metadata reads and the state file all go through it. No caller opens
  a SQLite connection, and no caller spells a schema name.
- **F6 still stands** (GDASH-1 findings G1-2): every new public name is checked
  against the stdlib and against gdash's own modules before it is used. The
  suite's override sweep covers the new modules from their first commit.

## 4. Tests

Tests first, hermetic, scratch-clean, as before. Additionally:

- **The due-decision gets a table test** — every policy against a fabricated
  clock, including the boundary where `every` has exactly elapsed.
- **A multi-dataset render test** joining across two dataset files, plus one
  asserting a twelfth dataset is refused at load with its golden message.
- **A dedupe test**: an unchanged refetch leaves the version file alone; a
  changed one bumps it.
- **A failure-surfacing test**: a dataset whose source fails shows its error on
  the page while its neighbours still render.
- **A sweep test**: crash residue is gone after a pass, and the audit log says
  so.
- **A draft-policy test**: a draft dataset with `interval` is refused a
  policy-driven refresh and still accepts a manual one.
- The end-to-end run grows a scheduler process, an interval that actually
  elapses, and an SSE reload driven by it rather than by a CLI refresh.

## 5. Done means

1. `on_open` and `interval` work end to end through a running scheduler, with
   `manual` unchanged.
2. A visual query joins two datasets, unqualified, and a dashboard over the
   attach limit is refused at load.
3. Draft and published data live in separate directories and draft-manual-only
   is enforced at the entry point, not by convention.
4. A failed refresh is visible on the dashboard, per dataset, with the old data
   still rendering; the audit log carries the event.
5. Crash residue is swept, and an unchanged refresh does not bump the version.
6. The hermetic suite and the live-Postgres runner both pass; findings
   recorded; DONE note names everything deliberately not built.

## 6. Deliberately not built

Publish, snapshots, rollback, session pinning (GDASH-3) — only the read side
of `current`, per §2.4. Auth, sessions, `user_*` (GDASH-4/5). The systemd unit
for the scheduler (GDASH-7). Cross-dashboard fetch dedupe and dataset sharing
(design §10). Pass-through queries. Retry-with-backoff on a failed refresh:
the next tick is the retry, and an exponential backoff wants an operator to
have asked for one. Per-dataset refresh from the UI: the manual refresh button
stays whole-dashboard until someone wants otherwise.
