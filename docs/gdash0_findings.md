# GDASH-0 — Step-0 findings

**Status:** step-0 verification complete; **phase halted before deliverables.**
**Date:** 2026-08-28
**Platform:** gBASIC 0.1.0-rc8 (`~/development/gbasic/gbasic`)
**Method:** every claim below was probed against the real binary. Nothing here is
read off a doc. Probe sources are throwaway; each finding states its repro.

---

## 0. Halt conditions (why the phase stopped here)

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
