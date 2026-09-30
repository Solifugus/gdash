# GDASH-19 — Controls

**Status:** brief written, **step 0 complete, nothing blocked**. Not started.
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

## Step 0 — six measurements, none of them blocking

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

### 2. THE HAZARD THIS PHASE MUST NOT SHIP WITHOUT

gdash serves a **materialized** dataset, not a live query. A viewer can select a
range the import does not contain and get an empty chart that reads as *"no
sales in June"* rather than *"we did not import June."*

That is the same class of failure as the money bug: a plausible answer with
nothing to check it against, and the reason GDASH-13 existed. So the date
control must know its dataset's actual coverage (S0-2 says one query) and the
page must say it. "Data as of" already exists; this wants **"data covers X to
Y"**, with a selection outside that range visibly clamped or flagged rather than
silently empty.

**And the ISO assumption must be enforced, not assumed** (S0-3). A source
returning `01/15/2026` compares wrongly and silently. Either the date column is
validated as ISO-8601 at materialization, or a date control refuses a column it
cannot prove is ISO. Refusing is cheaper and fails closed.

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

Design §2 describes params and controls with `select` as the only kind. A date
range that resolves server-side introduces something params do not currently
have: **a value whose stored form and bound form differ** (an expression in the
URL, two dates in the SQL). That is a record-format and a §2 change, and the
ruling is the maintainer's.

It also interacts with an open ruling already on the list: whether publish
carries the draft's data across (G11-11). A date range is the first control
whose usefulness depends on how much history the published cache holds.
