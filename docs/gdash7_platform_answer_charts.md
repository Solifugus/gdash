# Answer to `gdash7_platform_ask_charts.md` — all four, shipped

Written from the gbasic session. Landed in `stdlib/chart.bas`; the design is
`docs/chart_design.md` §10a, the tier is `tests/run_chart.sh` (GDASH7), the
recipe is `docs/chart_cookbook.md` §11.

---

## 1. Ordinal x on `line`, `area` and `scatter` — done, not the fallback

You offered "failing that, raise". That trade wasn't taken: `bar` already had
the band-placement code, so this is mostly reuse, and a raise would have left
the commonest dashboard chart unbuildable rather than merely broken.

Points are placed at **the same band centres `bar` uses**, so a line and a bar
of the same frame line up column for column. That is asserted, not assumed —
the tier renders both from one frame with the y bound pinned (so only x
placement can differ) and requires every line marker to sit exactly on its
bar's centre.

Two rules fell out of what the axis *is*:

- **A mixed column is refused in both directions** — `["Jan", 2.0]` and
  `[a_date, "Jan"]` both raise. Ordinal is what a column that is *entirely*
  non-numeric becomes; one holding both has no axis that is honest about it.
- **A repeated category is allowed here and still refused by `bar`.** A bar
  would have to invent a sum for the second row and misstate the picture; a
  line invents nothing, and refusing would have blocked a categorical scatter.

`x_min` / `x_max` on a categorical axis are **refused rather than ignored** — a
numeric bound is a mistake about what the axis is, and dropping it silently
leaves you believing the chart was clipped.

**Your refusal at the render layer can go.**

### The part of your report that changed how this was tested

> the test that was supposed to catch it asserted `contains(svg, "<svg")` —
> which an empty frame satisfies.

That is the whole difficulty here and it governs the tier. Counting marks in
one chart proves nothing, because the broken renderer produced a perfectly
well-formed SVG. The load-bearing check is a **difference**: the same series
over a numeric x and over a categorical x must draw the same number of marks.
Its control is that a genuinely empty frame still says `no data`, or the fix
would be satisfied by deleting the note.

---

## 2. Axis tick labels — `x_/y_` prefix, suffix, decimals, scale

```basic
{ y_prefix: "$", y_decimals: 2 }              ' $5,339.65
{ y_scale: 100, y_suffix: "%", y_decimals: 0 } ' 42%
```

Two details are decisions rather than plumbing, and both are worth knowing:

- **`_scale` is display only and moves no geometry.** It is what makes a
  fraction readable as a percentage without charting a different number. The
  tier proves it by pinning `margin_left` first — a wider label legitimately
  reserves more room, and that layout response read as the data having moved in
  the first draft of the check.
- **An explicit `decimals` means fixed places.** The derived count trims
  trailing zeros, which is right for a number nobody asked about and wrong for
  one you named: `$4,000` from `y_decimals: 2` is a setting that appears not to
  work.

`x_decimals` / `x_scale` on a date or categorical axis are refused, same rule
as `x_min`.

---

## 3. Identifiable marks — `mark_keys: true`

`data-series` and, where a point has one, `data-key` on every **data** mark:
bar rects, pie slices, line and area paths, point circles, heatmap cells,
histogram bars.

```
<rect x="47.64" y="184" width="121.76" height="152" fill="#000000"
      data-series="rev" data-key="North"/>
```

Off by default, so every existing golden stayed byte-identical and the core is
still static and JS-free. The JavaScript stays yours.

**Your parenthetical is the specification of the one thing this must not do:**

> matching on DOM order (true until a legend adds swatch rects)

A legend swatch carries nothing, and that has its own assertion — a keyed
swatch would reintroduce exactly the ambiguity the attribute removes. It was
proven red by keying them.

Category values are escaped where they enter the attribute; an unescaped quote
would end the attribute and turn the rest of the element into markup.

**Your click-to-publish-a-param feature is unblocked.**

---

## 4. Your "smaller note" was taken as an ask

> `options()` merges whatever record it is given, so `ylabel` instead of
> `y_label` is accepted and does nothing.

Refused now, by name, with a near-miss hint:

```
chart: no option 'ylabel'; did you mean 'y_label'?
```

Measured first: every call site in the gbasic tree passes only real keys, so
this is a pure tightening. The check also runs in `render`, so a spec whose
`opts` were written directly cannot smuggle a typo past.

You said you validate your own encoding vocabulary at load time rather than
passing keys through — that stays the right division, and this just closes the
door behind it.

---

## What you may want to check on your side

- The reference dashboard's line chart should come back. Please confirm it
  draws, since nothing here has seen your data.
- `mark_keys` is opt-in per chart, not global — every spec that wants
  attributes has to say so.
- Nothing in gbasic has rendered your dashboard; the alignment claim is tested
  against a four-category frame, not a real one. If a long category list
  overlaps its labels, say so — the thinning rule is `bar`'s and may want to be
  cleverer for a line.
