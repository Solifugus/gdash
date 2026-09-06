# GDASH-7 — Chart vocabulary and rendering depth: phase brief

**Status:** OPEN. Step-0 complete and written up in `gdash7_findings.md`
(G7-1 … G7-7).
**Narrows:** the GDASH-7 paragraph of `gdash_development_plan.md` (the phase
the numbering note calls chart vocabulary; deployment is GDASH-8).
**Authority:** `gdash_design.md` outranks this brief. The findings of GDASH-0
through GDASH-6 are inputs, not open questions.

---

## 1. Step-0 verification

- **Six chart kinds exist that gdash does not wire** (G7-1). The mark set grows
  by translation, not by platform work — the opposite of what GDASH-5's
  step-0 found and the reason this phase is cheaper than budgeted.
- **The option vocabulary already covers titles, axis labels, legends,
  palette, grid, stacked and ranges** (G7-2), but only through the spec chain;
  the convenience wrappers gdash calls take no options. Moving off them is the
  gate for everything else.
- **A line chart with a categorical x renders an empty frame, silently**
  (G7-3), in a mark gdash ships. `bar` handles the same data correctly.
- **Axis tick labels cannot be formatted** (G7-4) — a money axis reads
  `5,339.65`, not `$5,339.65`. The phase's one platform ask.
- **`chart.options` ignores unknown keys** (G7-5), so refusing a typo stays
  gdash's job, at load time.
- **`fake` is ready** (G7-6): realistic dashboards need no hand-written
  fixtures.

## 2. Scope

### 2.1 The silent empty chart, first

G7-3 is shipped, silent, and in the most natural line chart anyone writes.
Nothing else in this phase matters as much, so it goes first and alone.

At render time gdash holds the rows. A visual whose mark requires a plottable
x, and whose x column is not plottable, **refuses** — the same visible error
box as any other render failure, naming the column and what it holds. An empty
chart that looks like a chart is worse than an error, because the viewer reads
it as "no data" and the author reads it as "working".

This is a defect fix, not new capability, and it lands before any mark is
added — adding `area` and `scatter` on top of it would multiply the trap by
three, since all three take the same x.

### 2.2 The spec chain, and the options it unlocks

gdash moves from `chart.bar(df, x, ycols)` to
`spec` → `x` → `y` → `options` → `render`. That is mechanical, and it is what
lets a record say:

| encoding key | chart option | note |
|---|---|---|
| `title` | `title` | already in the record, currently rendered by gdash outside the SVG |
| `x_label` / `y_label` | same | new |
| `legend` | `legend` | new; default on when a `series` channel is bound, off otherwise |
| `stacked` | `stacked` | new; `bar` and `area` only |
| `y_min` / `y_max` | same | new; a truthful axis is a decision, so it is the author's |
| `grid` | `grid` | new |

Every key is validated at load time with a pinned refusal (G7-5), and every
one that is only meaningful for some marks is refused on the others — the
rule `series`, `formats` and `currency` already follow.

### 2.3 The mark set

Added: **`area`**, **`scatter`**, **`pie`**. Each needs a channel rule, a
validation refusal, an encoding→spec translation and a golden entry.

- `area` and `scatter` take the same `x`/`y`/`series` shape as `line`, so they
  inherit §2.1's plottability rule.
- `pie` takes a **label** channel and a single **value** channel, and the
  library refuses two value columns with a clear message; gdash refuses it
  earlier, at load time, so the author does not need a database to find out.

**`histogram`, `heatmap` and `sparkline` are named and not built.** A histogram
bins raw rows, which is a different contract from "the SQL is the single place
shape is decided" (design §2) — the record would have to carry a bin count and
gdash would be aggregating, which it does not do. A heatmap needs a two-
dimensional channel vocabulary that no other mark uses. A sparkline belongs in
a table cell, and the table mark has no cell-renderer concept.

### 2.4 The theme layer

A server-level theme file, `<config>/theme.json`, mode 0644 — it holds no
credential and an operator may want it readable. It carries the palette and
the font size, and nothing else until something demands more.

A record may override **per-series colour** and nothing else, because that is
the knob the plan names and the one an author has a real reason to reach for
(a series that must be red because every other report in the company draws it
red). Everything else is the deployment's business, not the dashboard's.

Absent file means the library's defaults, which are already colourblind-safe.

### 2.5 Interactivity, within design §5

Workers share no in-memory state, so both of these ride the existing
mechanisms and neither invents a new one:

- **Tooltips** are pure client-side: the shim reads values already present in
  the rendered SVG. No round trip, no state.
- **Click-to-publish-a-param** reuses the slicer path exactly. A click on a
  bar publishes the category as a param value through the same
  `POST /d/{name}/params` that a `select` control uses, and exactly the
  visuals binding that param re-run. The record opts in per visual by naming
  which param a click publishes; without it, a click does nothing.

If either needs a worker to remember something, it is out of scope and that is
a finding.

### 2.6 Downsampling, as documentation

A line chart over a hundred thousand rows is a SQL problem, not a rendering
one. The format doc gains a short section showing the bucket-and-aggregate
pattern, because the honest answer to "my chart is slow" is a `group by`, and
design §2 says the SQL is where shape is decided.

## 3. Construction rules

Unchanged, and additionally:

- **A chart that cannot draw the data says so.** No mark may render an empty
  frame where data was expected. This is the rule G7-3 exists to establish and
  it applies to every mark added here.
- **Every new encoding key is refused when meaningless.** A `stacked` on a
  `value` mark, a `pie` with a `series` channel: load-time refusals with
  pinned messages, like every key before them.
- **Tests observe themselves failing** (GDASH-6's rule, kept). A rendering
  assertion is checked against the feature removed, and the assertion audit
  runs on every end-to-end needle.
- **No aggregation in gdash.** If a mark needs binning, bucketing or rollup,
  it is out of scope; the SQL does that.

## 4. Tests

- **Plottability**: a categorical x on `line`, `area` and `scatter` refuses
  with a message naming the column; the same data on `bar` still renders.
  Asserted through gdash's own render path, not the library's.
- **Each new mark**: renders, and its refusals are in the golden.
- **Options**: each one reaches the SVG — asserted by rendering with it on and
  off and requiring the output to differ in the specific way named, never by
  matching a string that the stylesheet or an empty chart also contains
  (GDASH-6, G6-6).
- **Theme**: absent file, present file, per-series override, and a malformed
  theme that must refuse rather than raise.
- **Click-to-publish**: the param reaches the query, and a visual that did not
  opt in does not publish anything.
- **A `fake`-backed dashboard** with enough rows and series to make legends,
  stacking and multi-series behaviour visible, used by the end-to-end run.

## 5. Done means

1. No mark renders an empty frame where data was expected; a categorical x on
   a line refuses, by name.
2. gdash renders through the spec chain, and every option in §2.2 is
   author-reachable, validated, and asserted to reach the SVG.
3. `area`, `scatter` and `pie` render, with their refusals pinned.
4. A theme file sets palette and font size; a record may override per-series
   colour; an absent or malformed theme fails safe.
5. A click on a bar publishes a param through the existing slicer path, and
   only where the record opted in.
6. The format doc documents the new marks, the new keys, the theme file and
   the downsampling pattern.
7. All runners pass; findings recorded; the DONE note names what is still
   uncovered.

## 6. Deliberately not built

`histogram`, `heatmap`, `sparkline` (§2.3, with reasons). Aggregation of any
kind. Axis tick formatting until the platform ask lands — gdash documents the
gap rather than post-processing the library's SVG, because rewriting somebody
else's markup with a regular expression is how a rendering layer becomes
unmaintainable. Per-visual themes, dashboards-wide colour scales, and any
palette editor. Animation, transitions, and hover states beyond a tooltip.
Drill-through, cross-filtering between dashboards, and anything that needs a
worker to remember a viewer.
