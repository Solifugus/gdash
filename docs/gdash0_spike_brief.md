# GDASH-0 — Vertical spike: phase brief

**Status:** COMPLETE. Step-0 verification and implementation both done; at the
review boundary. Findings in `gdash0_findings.md`; DONE note in §9.
**Narrows:** the GDASH-0 paragraph of `gdash_development_plan.md`.
**Authority:** `gdash_design.md` outranks this brief. Where this brief is
silent, the design rules; where the design and an implementation disagree, that
is a finding, not an edit.

This brief narrows the plan. It never widens it. Every deferral is named in §7
so that deferring stays a decision rather than an omission.

---

## 1. The one thing this phase proves

That the spine holds end to end on shipped platform pieces:

```
one record → validation → refresh child (pg → SQLite, minor-unit money)
  → rename-swap + version bump → visual queries → SVG fragments
  → one slicer round-trip → SSE refresh notification
```

GDASH-0 is a **spike**: it proves the path is real and finds what it costs. It
is not a foundation to be preserved. Breadth at any station is GDASH-1+'s job;
this phase builds the narrowest thing that can carry a value from Postgres to a
pixel and back through a parameter.

The findings gate everything after. A station that cannot be made to work is
reported, not designed around.

## 2. Step-0 verification — DONE

Recorded in `gdash0_findings.md`. Four results bind this phase's implementation:

- **F1 — money.** gBASIC numbers are IEEE-754 doubles; integers above 2^53 are
  silently truncated in **both** directions across the SQLite binding. Real
  headroom at scale 2 is ~$90 trillion, not design §4's ~$92 quadrillion, and
  it binds per value *and* per aggregate result. **This phase adopts the text
  boundary discipline** (§4.3) rather than waiting on a §4 rewrite: minor-unit
  integers that can exceed 2^53 cross the gBASIC boundary as decimal *text*,
  never as numbers. Cheap now, expensive to retrofit.
- **F2 — parameters.** `sqlite.query` binds positional `?` with an array only.
  gdash owns the `:name` → `?` rewrite. The scan that performs it **is** the
  dependency-graph scan (design §2, "derived, never declared") — one scan, two
  consumers.
- **F3 — `load` scope.** A module is visible only inside the block that loads
  it. Every `program` block and every server handler carries its own `load`
  lines. Not a workaround to be cleaned up later; it is the idiom.
- **F4 — no `sqlite.columns`.** Load-time red/green is therefore **partial** in
  this phase, exactly as design §2 provides for: bindings, layout references,
  identifier legality and param placement validate before any database is
  touched; **encoding-channel names cannot** and are checked at first refresh.
  Say so in the report; do not simulate the missing check.

## 3. Scope — the narrowing

### 3.1 Exactly one record

One reference dashboard, committed, `format: 1`. Its shape is fixed here:

- **one dataset** — named, legal SQL identifier, one fetch SQL, `refresh:
  manual`, one money column declared `{ "type": "money", "scale": 2 }`.
- **one param** with a default.
- **one control** — a `select` publishing that param, its options from a query
  over the dataset.
- **two visuals** over the one dataset, **one `bar` and one `value`**. **One
  binds the param; one deliberately does not.** Two is the minimum that can
  prove the design's central interaction claim — that exactly the binding
  visuals re-run and the other stays put. One visual would prove nothing. Two
  *different* marks additionally prove the encoding → mark dispatch generalizes
  rather than being a single hard-coded path, and `value` is the mark that
  renders a money column through the format layer, so it carries §4.3's text
  boundary all the way to the pixel.
- **one tab**, a `vert` containing a `horiz`. Nesting is exercised because the
  layout walker must recurse; nothing more is asked of it.

### 3.2 The stations, each at its minimum

| Station | In scope | Held back |
|---|---|---|
| Validation | dataset-name legality; every `:name` resolves; **params absent from dataset queries**; every layout leaf names a defined visual/control | full catalog, golden refusal messages, dead-`space` warning (GDASH-1) |
| Refresh | one dataset, **manual only**, `process.start` child, parent supervision with `force_after` | interval/`on_open` policies, scheduling, multi-dataset, dedupe (GDASH-2) |
| Money | INTEGER minor units, per-column scale in `_gdash_meta`, excess decimals **rejected** | the wider format map; `currency` is the only format (GDASH-1) |
| Swap | `atomic_replace` over `<dataset>.db`, then version-file bump | staging sweep for crash residue (GDASH-2) |
| Visual queries | plain SELECT against the dataset file, `:name` rewritten to `?` | ATTACH across multiple datasets (GDASH-2) |
| Render | `bar` and `value` only, dispatched by mark name | every other mark, `series`, legends, theming (GDASH-1/6) |
| Slicer | one param POST → re-rendered fragments for binding visuals only | client-side niceties beyond the shim |
| SSE | one stream, polls the version file, emits `refresh` | `publish` events (GDASH-3) |

### 3.3 Access, without building auth

GDASH-4 owns identity. This phase builds **no** auth, no sessions, no users.

To keep design §8's fail-closed invariant true from the first commit rather than
retrofitting it: **the server serves a dashboard only if its record declares
`access: open`, and refuses every other record with a clear message.** A record
with no `access` key is refused. This costs one comparison, and it means the
default is closed on day one — no window exists in which "no auth yet" silently
means "open to all".

## 4. Construction rules

### 4.1 Modules

Built as separate modules from the start, because the boundaries are design
rulings and not refactors to be discovered later:

- `gdash_paths` — **the resolver.** `--root <dir>` collapses every role for dev
  and tests; FHS when installed. **No path literal exists outside this module**
  (CLAUDE.md). Resolved roles logged at startup.
- `gdash_record` — load, `try_decode`, shape check, validate.
- `gdash_store` — **all** staging-store access: create, insert, swap, select,
  `_gdash_meta`. The money text boundary (§4.3) lives here and nowhere else.
- `gdash_source_pg` / `gdash_source_fixture` — the seam (§5).
- `gdash_refresh` — child entry point and parent supervision.
- `gdash_render` — encoding → chart-library call.
- `gdash_server` — routes, fragments, SSE.

### 4.2 Credentials

Never in records, argv, commits, or fixtures. The child receives its profile via
a 0600 temp file (design §3). Test profiles use obviously-fake values. This is
verified by a test that greps the record and the process's argv, not by
inspection.

### 4.3 The money text boundary (from F1)

A minor-unit value crosses into gBASIC as decimal **text** wherever it could
exceed 2^53: aggregate in SQLite, return `cast(x as text)`, construct the
`money` value from the string. Never `minor / 10^scale` in gBASIC — that
division is itself a 2^53 hop. Source decimals with more places than `scale` are
**rejected, not rounded**, and the rejection is tested with a value that would
round cleanly, so the test fails if anyone "helpfully" rounds later.

## 5. Tests

Tests first wherever a behavior can be pinned. The suite is **hermetic**: it
runs under `--root` in a temp dir, needs no network, no live database, no
display, and ends with a **scratch-clean assertion**.

**The fixture-source seam** is what makes that possible. `gdash_refresh` names
its source by profile *kind*; `gdash_source_fixture` yields rows — including the
money strings — from a committed file with the same row shape `pg` returns
(design §4: `pg` hands back `numeric`/`bigint` as strings, so the fixture hands
back strings too, or the seam lies about the thing it stands in for).

**Live-pg runner:** a separate, opt-in runner gated on `GDASH_POSTGRES_TEST=1`
(CLAUDE.md convention), proving the same refresh against a real server. It is
never part of the hermetic suite.

Behaviors to pin, at minimum: each validation refusal; excess-decimal rejection;
`:name` → `?` rewrite, **including `:name` inside string literals and comments**
(F2 puts a correctness-sensitive rewriter on the critical path — it gets adverse
tests, not happy-path ones); a failed refresh leaving the old dataset file
**byte-identical**; the swap's stale-but-coherent read; a slicer round-trip
re-rendering the binding visual and **not** the other; SSE emitting on a version
bump; `access` fail-closed.

## 6. Done means

1. The reference record renders in a browser against fixture data under
   `--root`.
2. A manual refresh moves a money value from Postgres (live runner) and from the
   fixture (hermetic) into minor units, and it renders correctly formatted.
3. A refresh made to fail leaves the previous dataset intact and the dashboard
   showing the older data.
4. Moving the slicer re-renders the binding visual and leaves the other alone.
5. A refresh notifies an open page over SSE.
6. The hermetic suite passes from a clean checkout with no services running, and
   leaves no scratch behind.
7. `gdash0_findings.md` carries what the spike cost, and this brief carries a
   DONE note naming everything deliberately not built.

## 7. Deliberately not built

Named so deferral is a decision: draft/publish/snapshots/rollback (GDASH-3); any
auth, session, CSRF or user store (GDASH-4); `user_*` injection and preview-as
(GDASH-5); every mark but `bar` and `value`, `series`, tabs beyond one, `space`/`gap`
semantics, the dead-`space` warning, the format map beyond `currency`, golden
refusal messages (GDASH-1); interval and `on_open` refresh, multi-dataset
ATTACH, staging sweep, content-hash dedupe (GDASH-2); themes, legends, axis
formatting (GDASH-6); systemd, FHS install, TLS, drain/reload (GDASH-7);
pass-through queries, dataset sharing, non-Postgres sources, a designer GUI
(deferred by design §10).

Load-time channel validation is not built **and cannot be** until
`sqlite.columns` ships (F4); the first-refresh fallback is the behavior this
phase pins.

## 8. Boundary

Implement, test, commit locally in focused commits. **Stop at the review
boundary and write the report. Never push.** Platform gaps found while building
are findings for the report and candidates for gbasic's `DOGFOOD.md`, filed only
through that repo's own process — nothing under `~/development/gbasic` is
modified from here.


---

## 9. DONE note

All seven §6 criteria met. The hermetic suite is 154 in-process assertions
across six suites plus 22 end-to-end assertions over a real HTTP server, green
from a clean checkout with no services running, ending scratch-clean.

**Built:** the resolver; the record loader and its validation subset; the SQL
binding scanner (one scan serving both the dependency graph and the positional
rewrite); the staging store with the money text boundary; the fixture and
Postgres sources behind one seam; the refresh child and its supervision; the
`bar` and `value` marks; the server with its shell, slicer round trip, manual
refresh and SSE; the CLI (`validate`, `refresh`); the reference record.

**Deliberately not built** — §7's list stands unchanged, with these to record:

- **The live-Postgres runner is written but UNEXERCISED.** A server is running
  on this machine, but no credentials for it were available, so
  `tests/run_postgres.sh` has been proven only to gate correctly (it skips
  without `GDASH_POSTGRES_TEST=1` and refuses without a user). Its assertions
  have never run. The pg → SQLite → minor-unit money path is therefore proven
  *through the seam*, not against a live server. That is the one §6 criterion
  met in the hermetic half only, and it is the first thing to run when
  credentials exist.
- **`gdash_sql` is a module the brief did not name.** The binding scanner is
  used by both `gdash_record` (dependency graph) and `gdash_store` (rewrite);
  putting it in either would have made the other depend on it backwards. Not
  scope, just structure.
- **Currency scale is per-dataset, not per-channel.** A `currency`-formatted
  channel takes its scale from the dataset's money columns, which must agree.
  An aggregate of minor units is still minor units at the same scale, so this
  is correct for the reference record and for anything shaped like it; a
  per-channel scale belongs with GDASH-1's format map.
- **`_stale_note` shows a file mtime**, not a recorded refresh time. Good
  enough to prove "data as of" is real; GDASH-2 owns the audited version of it.
- **No audit log.** Design §8 lists the events; every one of them belongs to a
  phase that is not this one.

**Design edits the maintainer owes**, both from findings and neither made here:
§4's money headroom (F1: ~$90 trillion, not ~$92 quadrillion) and §4's render
path (F5: the money type is double-backed and cannot be the format layer above
2^53).
