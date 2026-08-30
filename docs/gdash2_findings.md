# GDASH-2 — Findings

Recorded as they were found, in the order they were found. Step-0 items are
verifications of the phase's premises; the rest are things the work turned up.
Platform items are findings for this report and candidates for gbasic's
DOGFOOD.md, filed only through that repo's own process (CLAUDE.md).

Checked against gBASIC `0d83ffb` (0.1.0-rc9 in development).

---

## G2-1 — There is no server-side timer, and the plan assumed one

**Step-0, and it fails.** The GDASH-2 paragraph of the development plan says
"per-dataset scheduling off the server's timer". No such timer exists.

- The `server` block admits exactly one hook. `src/frontend.c:371-373` refuses
  every other name: *"unknown hook 'on %s' (only 'on drain' exists)"*.
- `main` **must return** for the event loop to run. `docs/reference.md` is
  emphatic about it — a loop after `serve` "binds the listener, prints the
  banner, sets `h.running` true and **accepts connections**, while every
  request hangs forever with no response and nothing on stderr."

So there is nowhere in the serving process to put a periodic task. Verified by
probe rather than inferred, because inferring is how F5 went wrong in GDASH-0.

The decisive part came from a second probe. A server declared `workers: 2`
runs `main` **three times** — the supervisor and both workers — because
`serve` with `workers: N` spawns copies of the whole program via
`process.self()`. A scheduler started from `main` would therefore run in N+1
copies, all racing to refresh the same datasets, and the number would change
silently whenever an operator tuned the worker count in `server.json`.

**Ruling:** the scheduler is a separate program over a pure due-decision, and
the server neither spawns nor supervises it (brief §2.2). The cost is a second
process for an operator to run — GDASH-7 owns its unit file. The gain is a
scheduler that cannot be multiplied by a configuration change, cannot pin a
request worker, and can be driven one tick at a time by a hermetic test.

This is not a platform defect. A timer hook would be a reasonable platform
ask, but a scheduler and a web server are different programs, and discovering
that by having the premise fail is a better outcome than a hook that made the
wrong shape convenient.

## G2-2 — Unqualified table names resolve across attached schemas

**Step-0, and it passes better than hoped.** With `regions.db` attached as
`regions`, a query says `join regions r` — not `join regions.regions r`.
SQLite resolves an unqualified table name through `main`, then `temp`, then
the attached schemas in attach order.

Multi-dataset visual queries therefore read exactly like single-dataset ones,
and the record needs no syntax for "which dataset does this table come from".
That is the design's cross-source join (§3) falling out with nothing spent.

## G2-3 — Ambiguous table names resolve silently, and `_gdash_meta` is in every file

The other half of G2-2, and it is a hazard rather than a gift. A table name
present in both `main` and an attached schema resolves to `main` **with no
error and no warning**. Verified: `select count(*) from dup` against two files
both holding `dup` answered from `main` without a word.

Every dataset file carries `_gdash_meta` (the per-column money scales,
design §4). Attach two datasets and there are two `_gdash_meta` tables; an
unqualified read gets whichever file happens to be `main`, which means a money
column would render at **another dataset's scale** — silently, and only for
dashboards with more than one dataset, and only for columns whose scales
differ. That is close to the worst shape a bug can have.

**Ruling:** every metadata read is schema-qualified, always, and that lives
inside `gdash_store` where no caller can forget it.

## G2-4 — The attach limit is ten

`attach database` fails on the eleventh with *"too many attached databases -
max 10"*. A dashboard is therefore capped at **eleven datasets**: one opened
as `main`, ten attached.

Taken as a load-time refusal with a golden message rather than a runtime
surprise, because a dashboard that validates and then fails to render at the
twelfth dataset is exactly the load-time red/green promise (design §1) being
broken.

## G2-5 — `sha256` returns bytes, and `len` will lie about them

`sha256()` is a builtin and returns the raw 32-byte digest. `len()` counts
**characters**, and a digest is not valid UTF-8, so `len` under-reported for
**138 of 200** probe digests; `byte_count` correctly said 32 every time.

Nothing is lost — the bytes are all there — but a digest is not a string you
may measure, compare by length, or put in JSON. `crypto.sha256_hex` is the
form to use. Recorded because the failure mode is a hash that looks fine in
every test that does not happen to hit one of the 69% of digests containing a
byte sequence `len` reads as one character.

## G2-6 — No non-blocking advisory lock

`lock(f)` is `flock(fd, LOCK_EX)` (`src/eval.c:4387`) with no `LOCK_NB`, so
"is someone else refreshing this?" cannot be asked without waiting for the
answer.

**Ruling:** serialize with a blocking `with lock` on a per-dataset lock file,
then **re-read the state after acquiring it**. A policy-driven refresh that
finds the dataset was refreshed while it waited stands down; a manual refresh
proceeds regardless, because a human asked for it. The recheck — not the lock
— is what removes the duplicate fetch, which is the right place for it anyway:
it also covers the case where the two refreshers never overlapped in the lock
at all.

A `lock(f, { wait: false })` would be a reasonable platform ask. It is not
needed here, and asking for it would be asking for a lock to do a job the
state file does better.

## G2-7 — `file_type` is documented to say "missing" and says `unknown`

New since GDASH-1 and genuinely useful: `file_type(p)` answers `"file"` or
`"folder"` on a plain string path without raising, which is what
`gdash_paths.path_exists` hand-rolls with `{file}=` and `on error goto next`.

But `docs/reference.md:4120` says the third answer is `"missing"`, and it is
`unknown` — `is_unknown(file_type("absent"))` is true and
`file_type("absent") = "missing"` is false. A caller following the
documentation writes a comparison that is never true, and on a *missing* path
that reads as "not a folder", which is the answer they wanted for the wrong
reason. It only bites when the distinction matters.

Documentation finding for the gbasic repo's own process. gdash keeps its own
`path_exists` rather than switching on the strength of a documented return
value that is not the actual one.

---

## G2-8 — I reported the override sweep as built, and it was not

GDASH-1's findings recorded F6 recurring inside gdash (G1-2) and said the
suite had gained a sweep for override warnings. It had not. There is no such
check anywhere in `ca9311b`; `grep -ri override tests/ scripts/` at the start
of this phase returned one unrelated line about a param default.

I wrote it in the report because it was the obvious remedy and I had decided
to do it, which is not the same as having done it. The finding is not that a
mechanism was missing — it is that a report said a mechanism existed on the
strength of an intention. That is the same failure as F5 in GDASH-0, where I
described the money type from the design rather than from `eval.c`, and it is
worth naming twice because it is evidently the shape my errors take.

Built here, for real: `tests/overrides_probe.bas` loads every gdash module
alongside `web`, `sqlite`, `crypto` and `chart`, and `run_tests.sh` fails the
suite if the interpreter says anything about an override. It currently passes.

## G2-9 — "data as of" was a single line, and became a lie at two datasets

GDASH-0's status line took `file_mtime` of *the first dataset* and labelled it
the dashboard's. With one dataset that is correct. With two it is a statement
about whichever dataset `keys()` happened to return first, and it stops being
true exactly when the datasets diverge — which is when a viewer most needs it.

No test caught it, and no test could have: every fixture, every test record
and the reference dashboard itself had exactly one dataset. The suite was
green over a monoculture. The reference record now carries two, so the case
exists to be tested at all, and the page carries one status line per dataset.

Recorded because the mechanism is general: a reference fixture that only ever
exercises the singular case makes a whole class of plural bugs invisible, and
the suite reports full health throughout.

## G2-10 — the content-hash dedupe I built is not the one the design names

Design §2 says the server MAY dedupe refresh work by content-hashing
**(source, query)** — sharing one fetch between two dashboards that ask for
the same thing. That is not what this phase built and the two should not be
confused.

What is built: the fetched **result** is hashed, and a refresh whose result
matches the stored hash discards its staging file, skips the swap, and does
not bump the version. It saves a rename and a broadcast, not a fetch. It earns
its place because every open tab reloads on a version bump, so a five-minute
interval over static data was reloading every viewer twelve times an hour to
show them the same numbers.

What is not built: sharing fetch work between dashboards. It needs a
cross-dashboard registry keyed on (profile, SQL), and dataset sharing is
deferred by name in design §10. Deferred with it.

The suite noticed the change immediately and correctly: the end-to-end SSE
test had been driving its notification by re-refreshing identical data, which
stopped bumping the version the moment the hash landed. It now refreshes data
that has actually moved, which is what it should have been doing anyway.

## G2-11 — the refresh state file went to `gdash_sched`, not `gdash_store`

The brief (§3) said the state file would go through `gdash_store`, since the
plan has that module's boundary hardening in this phase. It did not, and the
brief was wrong rather than the code.

`gdash_store` is the **staging store**: SQLite files, the money boundary, the
swap. Design §3 contains it so that a future backend swap is one module's
rewrite. The refresh state is a small JSON file about *scheduling*, and it is
read by the page, the scheduler and the supervisor alike; putting it in
`gdash_store` would have widened that module's contract from "the staging
backend" to "anything stored", which is the containment the design ruling
exists to prevent.

What did harden in `gdash_store`, as the plan intended: attachment, every
schema-qualified metadata read, and the content hash. No caller opens a SQLite
connection or spells a schema name.

## G2-12 — the end-to-end run writes GDASH-3's `current` pointer by hand

`tests/e2e_publish.py` writes `snapshots/0001.json` and a `current` pointer for
three dashboards, because a policy refresh only applies to a published
dashboard (design §3) and GDASH-3 owns publish.

Named rather than buried: it is a test reaching into the next phase's format.
It is also the minimum that makes this phase's central deliverable testable at
all — without it the scheduler has nothing to schedule and `interval`,
`on_open`, the published data directory and draft-manual-only are all
unexercised. The read side is one function (`gdash_paths.publication`) and the
write side is one file, so if GDASH-3 rules the pointer differently, both move
together and neither is load-bearing anywhere else.

## G2-13 — with no scheduler running, a policy is silent

The consequence of G2-1, stated as its own finding because an operator will
meet it. `gdash_server.bas` neither spawns nor supervises the scheduler, so a
deployment that starts only the server has dashboards whose records say
`interval` and whose data never moves. Nothing is broken; nothing happens.

Mitigated rather than solved: the per-dataset status line says when each
dataset last refreshed, so "never" and "four days ago" are visible on the
dashboard itself rather than only in a log nobody reads. The format doc says
plainly that policies need a scheduler. GDASH-7 owns the unit file that makes
this the default rather than a thing to remember.

The alternative — the server spawning it — is what G2-1 rules out: it would be
spawned once per worker plus one, and the count would change silently whenever
an operator tuned `workers` in `server.json`.
