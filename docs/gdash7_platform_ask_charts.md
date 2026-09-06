# For the gbasic session — two asks from gdash's chart layer

Both are the Studio shape: general capability in `chart`, gdash as first
caller. The first is urgent because it makes a shipped mark unusable for the
commonest dashboard chart there is; the second is smaller.

---

## 1. A line, area or scatter over a CATEGORICAL x draws nothing, silently

```basic
chart.line({ t: [1.0, 2.0, 3.0],       v: [4.0, 8.0, 6.0] }, "t", ["v"])
    -> 1721 bytes, <path> x1        the line is drawn

chart.line({ t: ["Jan", "Feb", "Mar"], v: [4.0, 8.0, 6.0] }, "t", ["v"])
    -> 1684 bytes, <path> x0        NOTHING is drawn
```

The second returns a complete, plausible SVG — axes, gridlines, fourteen text
elements — with no data in it. No raise, no warning, nothing in the output that
distinguishes it from a chart of an empty result set.

`bar` handles the same categorical x correctly, which is what makes this a trap
rather than a documented limitation: moving one visual from `bar` to `line`
loses the data and says nothing.

### Why it matters more than the example suggests

**"Revenue by month" is the most common dashboard chart in existence**, and its
x axis is almost always a period label — `2026-01`, `Jan`, `Q3 FY26`. A time
series whose x is a formatted period is not an edge case; it is the default
case. gdash's own reference dashboard has had a blank line chart for six
phases because of this, and the test that was supposed to catch it asserted
`contains(svg, "<svg")` — which an empty frame satisfies.

### The ask

**Support an ordinal x on `line`, `area` and `scatter`**: when the x column is
not numeric, place points at evenly spaced positions and label the axis with
the categories, exactly as `bar` already does. That is what every charting
library does, and `bar`'s axis code presumably already has most of it.

Failing that — **raise**. `chart.pie` already refuses two value columns with a
clear message; the same treatment here ("a line needs a numeric x; column 't'
holds text") would be strictly better than the current silence, and would have
cost gdash nothing to discover.

gdash now refuses at its own render layer and names the column, so it is no
longer exposed. That refusal is a stopgap, and if ordinal x lands it goes away
and the reference dashboard becomes a line chart again.

---

## 2. Axis tick labels cannot be formatted

Tick labels come from `_fmt(t, ty.decimals, true)` — decimals derived from the
tick step, thousands separators on. Nothing in `_defaults()` reaches it.

So a money axis reads `5,339.65` where every other number on the dashboard
reads `$5,339.65`, and a percent axis reads `0.42` where the table beside it
reads `42%`. gdash formats values correctly everywhere except the one place a
viewer looks to read the scale.

### The ask

Options along the lines of `y_prefix` / `y_suffix` / `y_decimals` (and the `x_`
equivalents), or a single `y_format` naming a style. Whatever shape suits the
library — the requirement is only that a caller can make an axis agree with the
numbers printed next to it.

gdash will not work around this. Post-processing somebody else's SVG with a
regular expression is how a rendering layer becomes unmaintainable, so gdash
documents the gap and waits.

---

## Smaller note: `chart.options` accepts unknown keys silently

`options()` merges whatever record it is given, so `ylabel` instead of
`y_label` is accepted and does nothing. Reasonable for forward compatibility,
and gdash validates its own encoding vocabulary at load time rather than
passing keys through — mentioned only so the division of responsibility is on
the record.
