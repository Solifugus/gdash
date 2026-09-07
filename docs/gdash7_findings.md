# GDASH-7 — Findings

**Status:** step-0 complete. It found a silent failure in a mark gdash already
ships, and a phase cheaper than budgeted everywhere else.
**Platform:** gBASIC `6086e15`, `chart` 1402 lines. Everything here was
rendered, not read.

---

## G7-1 — six chart kinds exist that gdash does not wire

The plan's GDASH-7 opens with "grow the mark set", and GDASH-5's experience
said to expect the platform not to have it. The opposite is true here.

`chart` implements **line, scatter, area, bar, histogram, pie, heatmap,
sparkline**. gdash validates four marks (`bar`, `line`, `value`, `table`) and
calls exactly two library functions — `chart.bar` and `chart.line`. Rendered
each kind against a real frame: every one produces SVG, and `pie` refuses two
value columns with a clear message ("a pie takes exactly one value column")
rather than guessing.

So most of this phase is **translation, not platform work**: encoding →
spec-chain, plus the validation vocabulary to describe the new marks in a
record. That is the cheap half of the plan's paragraph, and it was budgeted as
the expensive half.

## G7-2 — the option vocabulary already covers most of "rendering depth"

`chart._defaults()` carries `title`, `x_label`, `y_label`, `legend`,
`palette`, `grid`, `markers`, `stacked`, `x_min`/`x_max`, `y_min`/`y_max`,
`max_ticks_x`/`max_ticks_y`, `font_size` and four margins. The palette is
Okabe–Ito, which is colourblind-safe by construction — a better default than
gdash would have chosen for itself.

Legends work, on every kind, with `legend: true` drawing series names and
`legend: false` removing them.

**But they are reachable only through the spec chain.** gdash calls the
convenience wrappers (`chart.bar(df, x, ycols)`), which take no options at all:

```basic
function bar(df, xcol, ycols)
    return render(y(x(spec("bar", df), xcol), ycols))
end function
```

Every option in this phase therefore requires gdash to move from the wrappers
to `spec` → `x` → `y` → `options` → `render`. That is a small, mechanical
change and it is the gate for titles, axis labels, legends and ranges alike.

## G7-3 — A LINE CHART WITH A CATEGORICAL X AXIS SILENTLY RENDERS NOTHING

**The finding that reorders the phase, and it is in a mark gdash ships today.**

```
chart.line({ t: [1.0, 2.0, 3.0],       v: [...] }, "t", ["v"])   1721 bytes, <path> x1
chart.line({ t: ["Jan", "Feb", "Mar"], v: [...] }, "t", ["v"])   1684 bytes, <path> x0
```

The categorical version draws **no data at all** — zero paths, zero polylines,
zero circles — and still emits axes, gridlines and fourteen text elements. It
returns a perfectly plausible chart. No raise, no warning, no empty-state
message.

`bar` handles the same categorical x correctly, which is what makes this a
trap rather than a documented limitation: an author moves one visual from
`mark: bar` to `mark: line` and the data disappears.

And "revenue by month" is the most natural line chart anyone writes. gdash's
own reference dashboard groups by a text `month` column. gdash validates that
the `x` channel names a column the query returns — it cannot validate the
column's *type* at load time, because design §1 forbids touching a database
then. But at **render** time gdash holds the rows, and that is where this must
be caught.

Ruling: **gdash refuses to render rather than render an empty frame.** A
visual whose mark needs a plottable x and whose x column is not plottable
produces the same visible error box as any other render failure, naming the
column. Whether `chart` should also refuse is the platform's question and is
asked; gdash cannot wait for the answer, because the failure is silent and
shipped.

## G7-4 — axis tick labels cannot be formatted, and that is gdash's core value type

Tick labels come from `_fmt(t, ty.decimals, true)`: decimals derived from the
tick step, thousands separators on. Nothing in the option vocabulary reaches
it.

So a money axis reads `5,339.65` where the dashboard says `$5,339.65`, and a
percent axis reads `0.42` where the table beside it says `42%`. gdash formats
values correctly everywhere except the one place a viewer looks to read the
scale.

This is the phase's platform ask, in the shape the Studio rule prescribes:
general capability (axis label formatting) in `chart`, with gdash as first
caller. Written up in `gdash7_platform_ask_axis_format.md`.

## G7-5 — `chart.options` merges blindly, so a typo is silently ignored

```basic
function options(s, rec)
    out.opts = _merge(out.opts, rec)
```

`legend_position` instead of `legend`, or `ylabel` instead of `y_label`, is
accepted and does nothing. That is a reasonable choice for a library that
wants forward compatibility, and it makes it gdash's job to refuse an unknown
encoding key **at load time** rather than pass it through — which is what
gdash already does for marks and channels, and must keep doing as the
vocabulary grows.

## G7-6 — `fake` is ready, and richer than the brief needs

50 functions, deterministic from `(base, index)`: `customers`, `invoices`,
`portfolio`, `person`, `company`, `address`, `phone`, `lognormal`, `weighted`,
plus a `plant` family for injecting anomalies. Realistic dashboards for
testing chart depth need no fixtures written by hand.

## G7-7 — a note on how G7-3 was nearly reported as something else

The first probe rendered every kind with a **categorical** x and concluded
that `line`, `area` and `scatter` never draw legends. That conclusion was
wrong. They draw legends fine; they were drawing *nothing*, so there were no
series to put in one.

Three kinds producing byte-identical output is what made me check rather than
write it down — and the check turned a false finding about legends into a real
one about empty plots. Recorded because the near-miss is the same shape as
G6-12: a measurement that agrees with itself across several cases is not
thereby correct, and identical numbers are a smell, not a confirmation.

## G7-8 — the interactivity half of §2.5 has no premise, and the library says so on purpose

Both deliverables — a tooltip on a bar, and a click that publishes a param —
need one thing: **a way to tell which mark was hit**. The library emits none.

```
<rect x="54.48" y="12" width="240.64" height="324" fill="#000000"/>
<rect x="355.28" y="174" width="240.64" height="162" fill="#000000"/>
```

Geometry and fill. No `id`, no `class`, no `data-` attribute, no `<title>` — a
search of all 1402 lines finds exactly one `<title>`, and it is in the
standalone-HTML wrapper, not on a mark. And this is deliberate:
`chart_design.md` §11 lists as v1 non-goals

> interactivity, tooltips, zoom, animation (SVG can host them later via a
> separate opt-in; the core stays static and JS-free)

**Ruling: not built, and not worked around.** The three ways to do it anyway
are all worse than waiting:

- **Rewrite the library's SVG in gdash.** The brief already forbids this for
  axis formatting, and the reason is the same: rewriting somebody else's
  markup with a regular expression is how a rendering layer becomes
  unmaintainable, and it would break on the next release that reorders an
  attribute.
- **Match marks by DOM order.** The bars are the only `<rect>` in a minimal
  chart, but a legend adds swatch rects and a grid adds lines; "the third rect
  is the second bar" is true until it is not, and nothing would announce the
  change.
- **Compute hit regions in gdash.** That needs the plot's margins, scales and
  tick decisions — a second implementation of the library's layout, guaranteed
  to drift.

A **fourth** option deserves naming because it looks reasonable and is not:
render a clickable strip of category labels beneath the chart, in gdash's own
markup. It would work. It is also, almost exactly, the `select` control gdash
already ships — a list of a column's values that publishes a param on click.
Shipping it would add a second way to do one thing and call it a feature.

The ask is in `gdash7_platform_ask_charts.md`: an **opt-in** that emits a
stable identifying attribute per data mark. That fits the design doc's own
sentence — attributes are static markup, and the JavaScript stays the caller's
problem, which is where gdash wants it anyway.

Recorded as GDASH-5's LDAP was: the phase narrows around the part the missing
premise never touched, rather than designing something else and calling it the
deliverable.
