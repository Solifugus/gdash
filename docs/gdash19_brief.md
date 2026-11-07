# GDASH-19 — Controls

**Status:** step 0 complete; **re-read against G-SQL and built under the
2026-11-07 rulings below** (GDASH-20 moved the store; this phase was held for
it).
**Independent of GDASH-15 … 18** (multi-tenancy) and may be taken before them:
it touches the record format, the renderer and the shim, and nothing the tenancy
work touches. Numbered after them to avoid renumbering three documents, not to
express an order.
**Authority:** `gdash_design.md` outranks this brief.

## Why this phase exists

gdash ships one control — a single-select slicer — and that was enough while
nothing else moved. What is now in play is the opposite question, asked by the
maintainer: **with natural-language querying there, how many controls does a
dashboard actually need?**

The answer this phase is built on: **NLQ removes the need for *many* controls,
not the need for controls.** It kills the "a filter per column, just in case"
instinct, which is the real disease in dashboard tools, and leaves a small
number that have to be genuinely good.

Four reasons, recorded because they are a design position and not a preference:

1. **Cost and latency are asymmetric by orders of magnitude.** A param change
   re-runs only the visuals whose SQL binds that param — tens of milliseconds.
   A question is 17–60 s of model time and, in the SaaS product, money against a
   per-tenant budget. For *"last month instead of this month"*, done ten times
   in a session, NLQ is the wrong instrument.
2. **Controls run reviewed SQL; questions do not.** The whole NLQ design
   produces a **draft** a person promotes, because a generated query can be
   confidently wrong — GDASH-12 step 0 returned 6 where 2 was correct, with zero
   reported problems. A slicer runs SQL an author reviewed and published. So
   controls are the *audited* path and NLQ is the *proposing* path; collapsing
   them would put unreviewed SQL in front of viewers on every interaction, which
   is precisely what the draft-visual shape exists to prevent.
3. **Row-level security lives in params.** `user_*` is injected last, over
   anything of the same name. A control is bounded by what the author wrote and
   by that injection; a question is bounded by the grounding, and grounding is a
   search — and a search always returns a winner.
4. **Repeat viewing is the product.** A dashboard's value is that tomorrow it is
   already right. Asking again each morning is a worse saved filter.

And an inversion worth naming for the SaaS product: **controls are the free
interaction and questions cost money.** That makes controls *more* important in
what is being built, not less.

## Step 0 — eight measurements, none of them blocking

### S0-1 — a date column materializes as `text`, and there is no date kind

```
plan_columns(["day","region","amount"], …)  ->  day -> text
_gdash_meta: [{"column_name":"day","kind":"text","scale":0}, …]
```

Undeclared columns map integer-looking → INTEGER, numeric → REAL, else TEXT
(design §4), so `2026-01-15` is TEXT. The record format has no `"type": "date"`.

### S0-2 — coverage is knowable, but only by asking, and nothing says which column is the date

`_gdash_meta` carries `column_name`, `kind`, `scale` — **no min/max**. Coverage
is one cheap query:

```
select min(day) as lo, max(day) as hi from t   ->   2026-01-15 .. 2026-03-28
```

Nothing in the record declares *which* column is a date, so a date control must
name its column. That is a fact about the design, not a defect.

### S0-3 — a range over ISO-8601 text compares chronologically

```
where day >= :from and day <= :to     from 2026-01-20 to 2026-03-01  ->  1 row
```

Correct, and **correct only for ISO-8601**, because lexical order is
chronological only for that format. See the hazard below.

### S0-4 — the same param may appear twice, and the dependency graph stays right

```
where day >= :from or day = :from      ->  ok, 2 rows
scan("… a = :from and b = :from and c = :to")
    names = ["from","to"]              <- the dependency graph, deduped
    order = ["from","from","to"]       <- the positional binding, expanded
```

So `:from`/`:to` need no new binding machinery, and a range query that uses a
bound twice re-runs exactly the visuals it should.

### S0-5 — multi-select needs no new binding idiom; gdash already has one

`user_groups` arrives as `|east|west|` and is tested with `like '%|finance|%'`,
delimiters on **both** ends so that a group merely *ending* in "finance" cannot
match. The same convention works in reverse for a selected list:

```
where :regions like '%|' || region || '|%'
    regions = "|west|"        ->  2 rows
    regions = "|west|east|"   ->  3 rows
```

Measured, working, and reusing a convention that is already documented and
tested rather than inventing a second one.

### S0-6 — `kind` is validated and not dispatched, which is a clean seam

```
control 'region_picker' has kind 'daterange'; this build implements 'select'
```

Validation refuses an unknown kind with a message that already anticipates more
of them. `gdash_render.render_control` does **not** branch on `kind` — it always
emits a `<select>`. So a new control kind is an additive change at two named
places: one validation branch and one render branch.

### S0-7 — incidental: the suite killed a server it did not start

Found because the demo server from the previous session was still running while
the suite ran. Not a controls finding, and worth recording where it happened.

Five suites (`run_e2e`, `run_workers`, `run_ceiling`, `run_drain`, `run_races`)
hardcode port 8780 and reap with:

```sh
for pid in $(pgrep -f "gdash_server.bas"); do
    [[ "$(cat /proc/$pid/comm)" == "gbasic" ]] || continue
    kill "$pid"
done
```

The name sweep exists for a good reason — the supervisor's **workers** are not
`$!`, so the script cannot simply kill the pid it started. The consequence is
that it kills *any* gdash server, including one a person deliberately started.
So running `make check` with a demo up did two things: the suite collided on the
port and failed, which looked like a flake; and then it silently killed the
demo, which looked like nothing at all.

**Fixed both ways, in all five.** PIDs that already existed when the suite
started are recorded and never killed, and an occupied port now refuses with a
message instead of failing obscurely:

```
port 8780 is already in use -- something else is serving on it.
  stop it first; this suite needs the port and will not kill a stranger.
```

Verified: with a demo server on 8780, `run_e2e.sh` exits 2 with that message and
**the demo survives**.

A footnote that earns its place: while clearing the port to re-run, I used
`pkill -f "gdash_server.bas"` and killed my own shell — exit 144, no output.
`run_e2e.sh` carries a comment warning about exactly that, ending "which cost an
hour once". The comment was right and being written down was not enough.

### S0-8 — a declared column type gdash does not implement is silently dropped

```
"columns": { "month": { "type": "date" } }   ->  ok=true  errors=[]  warnings=[]
```

It validates clean. `plan_columns` special-cases **only** `money`; everything
else falls through to inference, so the column materializes as `text` and the
declaration has **no error, no warning and no effect**.

Compare the control side, which gets this right (S0-6):

```
control 'region_picker' has kind 'daterange'; this build implements 'select'
```

The same posture is missing one level down. An author who declares a type gdash
does not implement should be told so, not ignored — and the fix is the same
change as the date work below.

## Rulings (maintainer, 2026-09-30)

**1. Bounds are recorded at import, not queried per render.** Better than the
per-render `min/max` this brief originally proposed: computed once per refresh in
the pass that already writes `_gdash_meta`, rather than once per page per
control, and it makes coverage a *declared fact about the data* alongside kind
and scale rather than something re-derived each time.

**2. The relative vocabulary as proposed stands** — `today`, `last_7d`,
`last_30d`, `last_90d`, `mtd`, `qtd`, `ytd`, `last_month`, `last_quarter`,
`last_year`, `custom`.

### What ruling 1 converges with, and why that is the shape

"Which columns get bounds" needs an answer, and the honest one is *the ones
declared as dates*. That single declaration resolves four separate problems:

| problem | resolved by `{"type": "date"}` |
|---|---|
| which columns get bounds recorded | the declared ones, and no others |
| the ISO hazard (S0-3) | **validated at materialization, rejected not coerced** |
| what a date control may point at | a column declared `date` |
| S0-8's silent drop | an unimplemented type becomes an error by name |

The ISO row is the load-bearing one, and it is deliberately the same posture as
money: design §4 says source strings with more decimals than the scale are
*rejected, not rounded*. A date column whose source hands back `01/15/2026` is
the same kind of problem and gets the same answer — fail the refresh, leave the
old dataset untouched, which is stale-but-coherent behaving as designed.

**`date` does NOT change the stored form.** Money declares a type *and* converts
(decimal text → INTEGER minor units); `date` declares a type and stores TEXT
unchanged. ISO-8601 already sorts chronologically (S0-3), so converting to epoch
integers would buy nothing and break every query an author has already written.
`date` means **validated and bounded**, not **converted** — worth stating,
because the money precedent invites the opposite assumption.

### Where bounds live: a sibling table, not more columns in `_gdash_meta`

`_gdash_bounds(column_name, lo, hi)`, written in the same pass. Three reasons:

- Existing readers do `select column_name, kind, scale from _gdash_meta`. Adding
  columns is fine for new files and wrong for old ones, and the store already
  carries a comment acknowledging that "a dataset refreshed by an older build
  could have one without the other".
- **A missing table is meaningful**: the dataset predates bounds, so coverage is
  *unknown* — and a control that says "coverage unknown" tells the truth, where
  one that claims an inferred range does not.
- No existing query changes.

### And "when a control is added" is validation, not state

Bounds computed at authoring time go stale at the next refresh, so they cannot be
the source of truth. What that moment *should* do is check: `gdash validate`
confirms a date control names a column declared `date`, and reports the current
coverage to the author as information. Feedback, not state.

## Re-read against G-SQL (2026-11-07)

Two of the 2026-09-30 decisions were made for SQLite, and both change:

- **Ruled 2026-11-07, reversing "`date` does NOT change the stored form": a
  column declared `{"type": "date"}` is a native G-SQL `date`.** The
  maintainer's words: "let's not be held by the limitations of something we
  are moving away from." Measured first, on the installed build:
  - the engine refuses `01/15/2026`, `15/01/2026`, `2026-1-5`, `2026-02-30`,
    `Jan 15 2026`, `20260115` and padded text. So the ISO check, and the
    "rejected, not coerced" stance, come from the engine, and gdash needs no
    date parser;
  - comparing with a text literal or a typed date param works;
  - `extract(month from day)` works, and the kind is reported as `date`;
  - charts draw over a date x-axis.

  The one gap is that text with a non-midnight time (`2026-01-15T10:00`) is
  stored with its time silently dropped. That contradicts gbasic's own
  conversion design, which says the column refuses it; asked as A7. The cost
  for authors: `substring(day, …)` no longer works on a declared date column,
  so write `extract`.
- **Bounds go in `_gdash_bounds(dataset, column_name, lo, hi)`.** It is still
  a sibling table, and it gains a `dataset` column because every dataset now
  shares one database. "A dataset with no bounds row says coverage unknown"
  stands.

**Found while re-reading: the page did not keep its params.** The shim posted
only the param that changed, and the server filled every other param from its
default. With one control nobody could tell. With a date range beside a
multi-select, changing one control would silently reset the other. The page
now holds every current value, sends them all, and keeps them in the URL, so
a bookmark carries a relative range as an expression, as Scope §1 requires.

## Scope

### 1. A date range — the one real gap, and the reason for the phase

Two rulings, both consequences of things gdash already does:

- **Relative expressions resolve server-side, at render time.** "Last 30 days"
  bookmarked in March must not still mean March in June, so the URL carries the
  *expression* and the server resolves it per render. This follows from params
  already round-tripping through the query string (`?region=east` works today).
- **A closed vocabulary, not an expression language**: `today`, `last_7d`,
  `last_30d`, `last_90d`, `mtd`, `qtd`, `ytd`, `last_month`, `last_quarter`,
  `last_year`, plus `custom` with an absolute `from`/`to`. Closed means
  **validatable at load time**, which is gdash's posture everywhere else.

It publishes two params, which S0-4 shows needs nothing new.

### 1b. `{"type": "date"}` — the declaration the rest hangs off

- **Any declared type gdash does not implement becomes a load-time error naming
  it**, which fixes S0-8 for every future type rather than only this one.
- `date` materializes as TEXT, unchanged, and is **validated ISO-8601 at
  materialization**. A non-ISO value fails the refresh with a message naming the
  column and the offending value, leaving the previous dataset in place.
- Bounds for every declared date column go into `_gdash_bounds` in the same pass.

### 2. THE HAZARD THIS PHASE MUST NOT SHIP WITHOUT

gdash serves a **materialized** dataset, not a live query. A viewer can select a
range the import does not contain and get an empty chart that reads as *"no
sales in June"* rather than *"we did not import June."*

That is the same class of failure as the money bug: a plausible answer with
nothing to check it against, and the reason GDASH-13 existed. So the date
control must know its dataset's actual coverage — recorded at import per ruling
1 — and the page must say it. A dataset with no `_gdash_bounds` says "coverage
unknown" rather than guessing. "Data as of" already exists; this wants **"data covers X to
Y"**, with a selection outside that range visibly clamped or flagged rather than
silently empty.

**And the ISO assumption is enforced at materialization** (S0-3, ruling 1): a
column declared `date` whose source hands back `01/15/2026` fails the refresh and
leaves the old dataset untouched, exactly as an over-precise money value does. A
date control may only name a column declared `date`, so it never has to guess.

### 3. Multi-select

The `|a|b|` convention from S0-5, documented in the record format as the way to
write the predicate, plus the UI. The delimiters are load-bearing and the
documentation must say why.

### 4. Reset

A dashboard with four controls and no way to clear them is one people reload to
escape. Nearly free: params already round-trip, so it is a link to the bare
path.

### 5. Drill-down — split into three, build one, document one, refuse one

- **Click-to-filter** — *already built* (`publishes` on a bar, point or slice).
  This is the 80% case and it ships today. Nothing to do but say so.
- **Drill to detail** — a `table` visual binding the same param. Likely
  expressible with no new code; the deliverable is to **verify that and
  document it as a pattern**, not to build machinery.
- **Hierarchical drill** with breadcrumbs — **refused**, see below.

## Deliberately not built

- **Hierarchical drill-down** (region → country → city, with a navigation
  stack). It needs a level concept, per-level grouping and breadcrumb state,
  and it is the feature most often asked for by someone who would be satisfied
  with two tabs and a click-to-filter. Deferred by name so the deferral is a
  decision.
- **A free-text search box.** A text box that is not NLQ is a worse NLQ, and one
  that is NLQ belongs on the ask page with its draft, its unit notes and its
  human review.
- **Chart-type toggles.** That is authoring, not viewing.
- **A numeric range or threshold control.** Plausible, unasked for, and it would
  be the second thing built on whatever the date range establishes.
- **A control per column**, which is the instinct this phase exists to avoid.
- **The visual query builder**, already deferred by name in design §10.

## Verification

- Load-time: every relative expression in the closed vocabulary validates; an
  unknown one is refused by name; `custom` without `from`/`to` is refused.
- Resolution: each expression resolves against an **injected clock**, so the
  vocabulary is pinned exactly without wall-time flake — the pattern
  `test_throttle.bas` already uses.
- The hazard: a range outside coverage is flagged, and asserted to be flagged
  rather than silently empty. A non-ISO date column is refused.
- Bookmarking: a relative expression survives a round trip through the URL as
  an *expression*, and resolves differently at two different injected clocks.
- Multi-select: one value, several, and none; and that a value containing the
  delimiter cannot escape its own list.
- End-to-end: a control changes a chart over HTTP, and only the visuals binding
  that param re-render.

## Owed to the maintainer

Two §2 changes and one §4, all record-format:

- **A date range introduces a param whose stored form and bound form differ** —
  an expression in the URL, two dates in the SQL. Nothing in §2 contemplates it.
- **`{"type": "date"}` is a new column type**, and §2's column map currently
  describes `{ type, scale, currency }` for money only.
- **§4 gains a second "rejected, not rounded" rule.** A non-ISO date is refused
  the way an over-precise money value is, and §4 is where that posture lives.

Decided in this brief rather than left open, because ruling 1 forces the question
and the money precedent answers it — but they are format changes and the shape is
the maintainer's to overrule.

It also interacts with an open ruling already on the list: whether publish
carries the draft's data across (G11-11). A date range is the first control
whose usefulness depends on how much history the published cache holds.

## DONE note (2026-11-07)

**Built.**

- **`{"type": "date"}` columns** are native G-SQL dates, as ruled 2026-11-07.
  A non-ISO or impossible date fails the refresh, naming the column, and
  leaves the old data in place.
- **Coverage is recorded at import.** Each date column's first and last day
  goes into `_gdash_bounds`, moved by the same transaction as the swap.
  `gdash_store.bounds` answers `{ known, lo, hi }`, so "unknown" and "covers
  nothing" are different answers.
- **A declared column type gdash does not implement is refused by name**
  (S0-8).
- **`daterange` control** (`gdash_controls`):
  - the closed vocabulary, resolved per request against an injectable today;
  - `custom` keeps its own dates;
  - validated at load: default expression, `from`/`to` declared `date`,
    column declared `date`;
  - an unknown expression at request time is a 400.
- **The hazard is closed:** the control prints "data covers X to Y" and flags
  a range that starts before the data, ends after it, is wider than it, or
  misses it entirely.
- **`multiselect` control** on the `|a|b|` convention. A list's default must
  be list-shaped, and a malformed list at request time is a 400. An option
  containing the delimiter is left out and counted, never silently dropped.
- **The page keeps its params** (found while re-reading):
  - every change sends the whole state plus `_changed`;
  - only the visuals binding what changed re-render;
  - a date range's expression moving counts as its two dates moving;
  - the controls whose param moved re-render too, so the coverage note
    follows the range;
  - the URL is updated, so a bookmark carries the expression.

  The params JSON is escaped on its way into the `<script>` (a test pins it
  against `</script>` in a param).
- **Reset** is a link to the bare path.
- **Drill to detail** is documented as a pattern: `publishes` on a chart, and
  a table binding the same param. Hierarchical drill is refused by name, as
  ruled.

**Verified.**

- `test_controls` (38): every expression at an injected clock, the year and
  leap-February edges, the bookmark property at two clocks, lists, and the
  load-time refusals.
- `test_store` additions: date storage, refusals, bounds through a swap,
  empty and unknown coverage.
- `test_record`: the S0-8 refusal.
- `test_app`: script escaping of the page's params.
- An e2e section over HTTP:
  - a custom range re-renders only the date-bound visual, with the right sum;
  - a multi-select re-renders only its own visual;
  - the coverage note follows the range;
  - a bookmark renders the same figure;
  - a bad expression and a malformed list are refused (400).

**Not verified by a dedicated test:** drill to detail. It relies on
click-to-publish and param binding, each of which is tested on its own.

**A7, done by the platform (gbasic `c9be074e`).** Text with a non-midnight
time stored into a `date` column is now refused (`TYPE`), where it used to
lose its time silently. `test_store` pins it through the store: a
datetime-shaped source value fails the refresh and says why, and midnight is
stored. The test fails on `0424a49` and passes on `c9be074e`.
