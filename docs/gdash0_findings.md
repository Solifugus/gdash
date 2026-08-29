# GDASH-0 — Step-0 findings

**Status:** step-0 verification complete; deliverables built; **at the review
boundary.** §§0–4 are the step-0 record (the halt described in §0 was cleared by
the maintainer, who supplied the repository and the brief). §5 is what
implementation surfaced.
**Date:** 2026-08-28
**Platform:** gBASIC 0.1.0-rc8 (`~/development/gbasic/gbasic`)
**Method:** every claim below was probed against the real binary. Nothing here is
read off a doc. Probe sources are throwaway; each finding states its repro.

---

## 0. Halt conditions — RESOLVED

Both were cleared by the maintainer after this section was written: the
repository was initialized on `master`, and `docs/gdash0_spike_brief.md` was
written and then amended to make the second visual a `value` mark. The record
below stands as written.

### The original halt

Two blockers, neither of which step-0 can design around. Per CLAUDE.md
("If a verification fails, stop and report — do not design around it").

### B1 — The phase brief does not exist

`docs/gdash0_spike_brief.md` is absent. `find` over `~/development` returns no
`gdash0*` or `*spike_brief*` file anywhere.

CLAUDE.md names that brief as **"the only scope that is in play"** and says a
brief "may narrow the plan; it never widens." The development plan's GDASH-0
paragraph is a one-paragraph roadmap entry that the plan itself says is *not*
the brief ("this plan is the roadmap, not the briefs"). Building from the
roadmap paragraph alone would be inventing the narrowing the brief exists to
supply — which is precisely the widening the house rules forbid.

`docs/` contains only `gdash_design.md`, `gdash_development_plan.md`, and this
file.

### B2 — The working directory is not a git repository

`git status` → `fatal: not a git repository`. There is no `.git` anywhere up the
tree. The method requires "implement, test, commit locally with focused commits"
and "stop at the review boundary"; there is no repository to commit into.

Not initialized unilaterally: choice of initial branch, `.gitignore` policy, and
whether this tree is meant to be a subdirectory of an existing repo are the
maintainer's calls, and B1 means there would be nothing to commit regardless.

---

## 1. Verifications that PASSED

These are the design's load-bearing platform premises. All confirmed on the real
binary.

| # | Premise (design §) | Result |
|---|---|---|
| P1 | gBASIC interpreter present and runnable | **PASS** — 0.1.0-rc8 |
| P2 | `sqlite` module: connect/exec/query/close | **PASS** |
| P3 | Cross-file join via `ATTACH` (§3) | **PASS** |
| P4 | Rename-swap is stale-but-coherent (§3) | **PASS** — see below |
| P5 | `process.start` / `process.wait` refresh child (§3) | **PASS** |
| P6 | `pg` module present (§9) | **PASS** — loads; live server untested (opt-in) |
| P7 | Chart library emits deterministic SVG text (§5) | **PASS** — 1285-byte bar SVG |
| P8 | `server` block serves an SVG fragment from a dataset file (§5) | **PASS** |
| P9 | SSE `stream` route emits events (§5) | **PASS** |
| P10 | `money` type renders exact minor units (§4) | **PASS** — `0.1+0.2 → 0.30` |

### P4 detail — the swap semantics are exactly as designed

`atomic_replace(temp, dest)` (a single `rename(2)`; **not** `rename`, which is
not a builtin — `move` is the non-atomic cross-device cousin). Probed with a
reader holding the old file open across the swap:

```
reader_before_swap: [{"v":1}]
reader_after_swap : [{"v":1}]   <- open handle keeps the old inode
fresh_after_swap  : [{"v":2}]   <- a new connection sees the new data
```

This is design §3's "open handles keep the old inode; readers reconnect on
version notice", confirmed end to end. Note `atomic_replace` guarantees atomic
*visibility*, not crash *durability* — it does not `fsync` the file or its
directory. Refresh-crash durability is a GDASH-2 concern, named here.

### P8 detail — the spine renders

A `server` block handler that opens a dataset `.db`, runs a visual query, and
returns `chart.bar_xy(...)` as `image/svg+xml` produced a real SVG over HTTP.
The GDASH-0 spine is viable on shipped platform pieces. **Subject to F3 below.**

---

## 2. FINDINGS

### F1 — Design §4's money headroom claim is wrong by ~3 orders of magnitude, and the failure is SILENT

**Severity: high.** This contradicts a stated design ruling, so per the house
rules it is reported, not silently edited into either document.

Design §4 states: *"SUM/COUNT/MIN/MAX/GROUP BY over 64-bit integers are exact
(~$92 quadrillion headroom at scale 2)."*

SQLite stores and aggregates `INTEGER` as exact int64. **The gBASIC binding is
the lossy hop, in both directions** — gBASIC numbers are IEEE-754 doubles, so
integers above 2^53 are silently rounded.

Repro (`2^53 + 1 = 9007199254740993`):

```
stored_as_text : [{"t":"9007199254740993"}]   <- SQLite stored it exactly
delivered_num  : [{"amt":9007199254740992}]   <- reading into gBASIC: -1, silently
param_in_astext: [{"t":"9007199254740992"}]   <- binding as a param: lost BEFORE it reached SQLite
sum_as_text    : [{"s":"18014398509481986"}]  <- SQLite's own SUM is exact
```

Real headroom at scale 2 is **2^53 minor units ≈ $90.07 trillion**, not 2^63
≈ $92 quadrillion. The limit binds on **each individual value and on every
aggregate result**, not just on column totals.

There is no error, no warning, and no exception — a cent silently disappears.
For a product whose §4 opens "money accuracy is critical," a silent wrong answer
is the worst available failure mode.

**The minor-units ruling itself survives** — it is not invalidated, only its
stated range. Two things follow, and both are design decisions the maintainer
must make, not step-0 edits:

1. **Range.** ~$90 trillion is ample for essentially all business finance. If
   that is accepted, §4's number needs correcting and the bound documented.
2. **Boundary discipline.** Where a value *can* exceed 2^53, it must not cross
   the gBASIC number boundary. The probe shows the escape hatch works today:
   aggregate in SQLite and return `cast(x as text)`, then render through the
   `money` type from the string. That is a rule for `gdash_store`, and it is
   cheap to adopt now and expensive to retrofit — which is why it is raised
   before any code exists.

Note the same 2^53 ceiling applies to the `money` render path if the minor-unit
integer is divided in gBASIC before being made a `money`; build the money value
from decimal *text*, not from `minor / 10^s`.

### F2 — `sqlite.query` does not accept `:name` parameters

**Severity: medium.** Design-relevant, not blocking.

```
sqlite.query(db, "select amt from orders where cust = :cust", { cust: 2 })
  -> RAISED: SQLite query parameters must be an array
```

The binding takes positional `?` with an array only, though SQLite itself
supports `:name` natively. Design §2 specifies `:name` bindings in query text as
the mechanism from which the dependency graph is derived.

This is **not** an obstacle to the design: gdash must scan query text for
`:name` anyway (that scan *is* the dependency graph, per §2's
"derived, never declared"). The same scan yields the binding order, so gdash
rewrites `:name` → `?` and builds the positional array itself.

Worth stating because it puts a small, security-relevant rewriter on the
critical path that the design does not currently name: it must handle `:name`
occurrences inside string literals and comments correctly, or it will corrupt
queries. It should be tests-first when it is built. Candidate platform ask
(named-parameter binding) for the gbasic repo's own process.

### F3 — `load` is scoped to the block it appears in, and the failure message misdirects

**Severity: high for anyone writing gdash; a doc/ergonomics defect, not a defect
in the design.** This cost the most time in step-0 and will cost every future
contributor the same unless written down.

A module loaded at **file scope is not visible inside a `program` block** (nor
inside a `server` handler). Minimal repro:

```basic
load chart from ".../stdlib/chart.bas"
s = chart.bar_xy(["a","b"], [1,2])        ' top level: WORKS
```
```basic
load chart from ".../stdlib/chart.bas"
program main(args)
    s = chart.bar_xy(["a","b"], [1,2])    ' runtime error: invalid function call
end program
```

**The workaround is simply to put the `load` inside the block that uses it**,
which works in a `program` block and in a `server` handler alike — that is how
P8 above was made to pass.

Two aggravating details:

- **The error message misdirects.** A path-loaded library reports
  `invalid function call: chart.bar_xy` — which reads as "you got the function
  name wrong" and sends you to check the library's API. The builtin form
  (`load sqlite`) reports the accurate `library not loaded: sqlite`. The
  accurate message should be used for both.
- **The gbasic repo's own server-block tests never call a `load`ed module from a
  handler** (`tests/web_server_block/*.bas` load nothing; the one handler test
  calls the handler as a plain function value returning a literal). So gdash is
  the first caller on this path — which is exactly the kind of unproven ground
  step-0 exists to find, and the reason P8 was worth probing rather than
  assuming.

Both are DOGFOOD.md candidates for the gbasic repo, to be filed **only** through
that repo's own process. Nothing under `~/development/gbasic` was modified;
`git status` there is clean.

### F4 — `sqlite.columns` is absent, exactly as design §9 predicted

```
sqlite.columns: ABSENT (invalid function call: sqlite.columns)
```

Not a defect — design §9 lists it as a *planned* platform ask, and §2 already
specifies the fallback: *"Until then channel checks happen at first refresh."*
Confirmed here so the fallback is a recorded decision rather than an assumption.
Load-time red/green is therefore **partial** in GDASH-0: bindings, layout
references, identifier legality, and param placement all validate before any
database is touched; **encoding-channel names cannot**. Whatever the brief says
about "load-time red/green" should be read with that limit in mind.

---

## 3. Corrections to my own probes (not platform defects)

Recorded so they are not mistaken for findings: `print` takes a single
expression (`print(a + b)`, never `print a; b`); `rename` is not a builtin
(`atomic_replace` / `move`); logical negation is `not`, not `!`; the chart entry
points are `chart.bar_xy(categories, values)` / `chart.line_xy(xs, ys)` and the
`spec`/`x`/`y`/`render` builder chain.

---

## 4. Recommendation

Unblock in this order:

1. **Write `docs/gdash0_spike_brief.md`** (B1) — the narrowing scope statement.
   Nothing else can start.
2. **Decide B2** — `git init` here, or place this tree in an existing repo.
3. **Rule on F1** — accept the ~$90 trillion bound and correct design §4's
   number, or mandate the text-boundary discipline in `gdash_store`. Either way
   §4 needs an edit, and that edit is the maintainer's, not step-0's.

F2, F3 and F4 need no ruling before implementation; they are constraints the
brief's implementation must respect, and F3's workaround is already proven.

Nothing was implemented, and no scope was assumed. No commits were made (there
is no repository). The gbasic repo was not modified.


---

# 5. Findings from implementation

Step-0 proved the platform primitives in isolation. Building on them surfaced
five more, in rough order of how much they cost.

## F5 — the `money` type has an exact core and a lossy entrance

**Severity: medium** (revised down from high, and re-diagnosed — see the
correction note below).

`src/eval.c` settles what money actually is:

```c
static Value value_money(long long cents) { ... }
static char *odbc_money_text(long long cents)   /* "Money is integer cents" */
```

It is an **exact int64 scaled integer** — the right representation, with the
full ±$92 quadrillion range at scale 2. Probes agree: `0.01` accumulated 1000
times yields exactly `10.00`, which a double cannot do, and printing renders
all 16 significant digits.

**The defect is not the storage; it is everything around it.** Three distinct
problems, around a correct core:

1. **Construction launders through a double.** A literal or `number()` result
   is a double before `value_money` sees it, so `big{USD}= 92233720368547.75`
   yields `...76` — a cent out. And the modifier **refuses a string**
   (`USD modifier expects a number`), so there is no exact way in at all. The
   type's own range is unreachable through its own constructor.
2. **`*` and `/` by a number leave integer arithmetic.** Both go through
   `round_to_cents(amount / 100.0)` on a `double`. So a money value that *was*
   exact silently degrades the first time it is scaled — arguably worse than
   (1), because it corrupts a value the caller had already got right.
3. **Scale is fixed at cents.** There is no per-currency exponent, so JPY
   (0 decimals) and anything at scale 4/6/8 has no money representation. This
   is the case that actually bites in practice: the 2^53 ceiling is
   unreachable at scale 2 (~$90 trillion) but sits at ~$9 billion at scale 6
   and ~$90 million at scale 8, and those are ordinary amounts for FX rates,
   per-unit costs, and crypto.

**Correction to the earlier write-up.** This finding previously said the money
type was "double-backed" and could not be the format layer. That diagnosis was
wrong — it was inferred from a probe that called `number()` first, which
destroyed the precision before the money type was involved. The storage was
never the problem. The conclusion gdash acted on still holds for a different
reason: with no string constructor, there is no exact path into the type, so
gdash's format layer works from decimal text either way.

**What gdash needs from a fix: nothing, to keep working.** gdash does money in
text and int64 in SQLite and never constructs a `money` value. But an exact
text constructor plus integer-preserving `*` and `/` would let gdash's
`from_minor`/`format_currency` delegate to the platform instead, which is the
Studio rule — general capability belongs in the library with gdash as first
caller. Suggested order, for the gbasic repo's own process to rule on:

1. **`m{USD}= "1250.75"`** — parse decimal text to cents by integer
   arithmetic. Small, and it alone makes the type's existing range reachable.
   Excess decimals should be **rejected rather than rounded**, matching what
   gdash does and what design §4 requires.
2. **Keep `*` and `/` in integer arithmetic** where the operand is integral;
   define the rounding rule explicitly where division genuinely needs one.
   This is the silent-corruption case.
3. **Per-currency scale**, which is a representation change and a real design
   question. Deferred unless demand appears — it is what would let a scale-8
   column use the type at all.

## F6 — library functions share one namespace, and collisions are silent

**Severity: high.** This was the single most expensive finding of the phase and
the one most likely to bite the next contributor.

There is no per-library namespace for function *definitions*. A function
defined in one library silently **overrides** a same-named function in another
loaded library, and the only signal is a warning on stderr.

It happened twice:

- `gdash_render._escape` overrode `chart._escape`. Cosmetic — caught by the
  warning, renamed to `_html_escape`. Note that the underscore prefix, which
  every stdlib library uses to mark a function private, provides **no isolation
  whatsoever**.
- `gdash_paths.resolve` overrode **`web.resolve`**. A `server` block implies
  `load web`, and the web library uses its own `resolve` for routing, so this
  broke *every route that did any work* while the trivial literal-returning
  route still answered — a failure that looks like "my handler is wrong"
  rather than "I renamed a stdlib function out from under the server". Renamed
  to `roles()`.

The second case is the dangerous shape: an ordinary, obvious name for a
resolver, taken by a stdlib module the program never mentions, breaking code
that never calls it. Any gdash module is one common noun away from repeating
it. Candidate platform asks, for the gbasic repo's own process: make the
override an error rather than a warning, or scope definitions to their library.

## F7 — no `chmod`, so a 0600 credentials file needs a subprocess

**Severity: medium.** Design §3 requires credentials to reach the refresh child
through a 0600 temp file. There is no permissions builtin, so `gdash_refresh`
shells out to `chmod` via `process.run`. It works and the job file is deleted
after the fetch, but a security-relevant property currently depends on an
external binary being present and on the call succeeding. `umask` at startup
plus a restricted `run_dir` would be a better belt; a `set_mode`-style builtin
would be better still.

## F8 — `load` takes a compile-time literal, so library paths cannot be resolved

**Severity: medium.** CLAUDE.md requires that no path literal exist outside the
resolver. `load chart from "..."` needs a literal at parse time, so the chart
library's location provably **cannot** go through the resolver. `gdash_render`
resolves it against the sibling layout CLAUDE.md documents
(`../../gbasic/stdlib/chart.bas`), which is right for a dev checkout and wrong
for an installed build. GDASH-7 needs a real answer — a vendored copy, an
install-time path, or a platform way to load by module name.

## F9 — an SSE body that emits only on change never learns its client left

**Severity: medium; a gdash lesson more than a platform defect.** `emit`'s
false return is the entire liveness protocol, so a stream that emits *only when
something changes* has no way to notice a departed reader, and holds its worker
until its own tick ceiling. The first end-to-end run hung on exactly this.

The stream now sends a comment heartbeat every few seconds, so a disconnect is
noticed promptly. This matters more here than it would elsewhere: design §5
already names the pinned worker as this architecture's ceiling, and a stream
that outlives its client spends that ceiling on nobody. Worth stating in the
GDASH-7 worker-sizing documentation the plan already calls for.

## Smaller platform notes

Recorded because each cost time and none is in `UNLEARN.md`:

- **`exists()` accepts only a *file* reference.** A directory reference raises
  `exists expects a file reference`. A file reference over a directory path
  answers correctly, so that is the one existence test for both kinds.
- **`list()` returns an empty array for a missing directory** rather than
  raising, so it cannot distinguish absent from empty and cannot serve as an
  existence test.
- **`make_dir` is neither idempotent nor parent-creating** — it raises on an
  existing directory. `persist.ensure_dir` exists in the stdlib; gdash has its
  own to avoid the dependency.
- **`on error goto next` is frame-scoped and does nothing at top level.** An
  error there terminates the program despite the guard. Every gdash entry point
  puts its work inside a `program` block or a function for this reason.
- **`try_decode` returns a result record** `{ ok, value, message, offset, line,
  column }`, not the decoded value. Treating the return as the document yields
  an empty record and a misleading validation failure.
- **A library alias must match the library's declared name.** `load t from
  "gdash_test.bas"` fails with `library not found: t`; there is no aliasing.

## F10 — a glibc upgrade blocks CREATE DATABASE until the templates are refreshed

**Severity: low for gdash; environmental.** Not a gdash or gBASIC defect,
recorded because it cost a round trip and will recur on any machine whose libc
moves.

`scripts/setup_postgres_test.sh` failed midway: Postgres refuses every
`CREATE DATABASE` when the template databases record an older collation version
than the OS now provides (here 2.42 → 2.43). The script now preflights and
refuses to guess, with `--fix-collation` refreshing only `template1` and
`postgres`. `template0` is left alone — it is locked against connections, so
refreshing it means flipping `datallowconn` in the catalog, and nothing here
needs it.

The wider point is deliberately left to the operator: refreshing a collation
version updates the recorded number without re-sorting anything, so a database
with real text indexes wants `REINDEX` first. On this machine every database is
development, so that was noted rather than acted on.

## What this means for the phase after

Nothing here blocks GDASH-1. F1 and F5 together mean **design §4 needs a
one-line correction** — the headroom figure is wrong and the limit is
scale-dependent — but at scale 2 the ceiling is unreachable in practice, so
this is housekeeping rather than urgency. F6 is the one to act on soonest, because it is a
trap the next module to be written will fall into, not a limit that merely has
to be lived with.
