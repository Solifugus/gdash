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

## G7-9 — `concat` is 242× slower than `append`, and gdash's pivot used it per row

Measured on this build, twenty thousand elements:

```
append 20k:   40 ms      (mutates in place, returns the array)
concat 20k: 9723 ms      (copies)
```

`_pivot` used `concat` in three per-row loops, deduped x values with a
`contains(keys, xv)` scan per row (O(n²) on top), and — worst of all — slotted
each value with `col = df[key]` / `col[slot] = v` / `df[key] = col`. **Arrays
are copy-on-write**, so that last pattern copies the whole column on every
row, and a mutation through an alias is not even visible:

```
outer = [[1, 2, 3], [4, 5, 6]]
inner = outer[0]
inner[0] = 99
outer[0][0] = 99        ->  false
```

A read-append-write-back loop measures 467 ms at four thousand iterations for
that reason alone.

At two thousand points the chart library spent 298 ms rendering and gdash spent
**870 ms on top of it** — three times the library's own cost, to reshape data
the library then drew. Fixed by using `append`, replacing the dedupe scan with
a `seen` record, and inverting the loops so each column is built as a local
that nothing else holds and assigned to the frame once:

| points | overhead before | overhead after |
|---|---|---|
| 500 | — | 26 ms |
| 1000 | — | 78 ms |
| 2000 | **870 ms** | **110 ms** |
| 4000 | — | 148 ms |

Linear now, and the library dominates, which is the right shape: gdash should
cost less than the thing it is calling.

**This was found while writing documentation telling authors to downsample.**
That is the part worth recording. The §2.6 deliverable is a SQL pattern for
large results, and measuring the cost to write it honestly is what exposed
that three quarters of the cost was gdash copying arrays. Advising someone to
work around your own defect is not advice.

## G7-10 — a measurement I could not reproduce, and did not publish

The first pass at G7-9 produced "1000 points: 0.8 ms" from one script while
another gave 217 ms for the same work — a 250× disagreement. I could not
explain it and did not use it. The reproducible measurement puts both paths in
**one script, on identical data, and checks the output sizes match** before
comparing times.

Recorded because the temptation was real: the fast number was the flattering
one, and it appeared first. Two measurements that disagree by two orders of
magnitude mean at least one is measuring something other than what it claims,
and the way to find out is to make them share everything except the thing
being compared.

---

# Platform update at gbasic `ca5df46`

## G7-11 — the cross-kind comparison change found a crash on the request path

The update said "your `x = 0` guards against possibly-text values are worth a
grep". They were. Ordering across kinds now raises, and gdash had a reader that
produced text where a number was expected:

```basic
function _num(v, fallback)
    if is_unknown(v) or is_nothing(v) then
        return fallback
    end if
    return v            ' <- never asked whether it WAS a number
end function
```

A state file containing `"last_success": "yesterday"` therefore reached
`st.last_success > 0`, and:

```
due() RAISED: a string and a number have no order;
              = and != answer, the ordering operators do not
```

`due()` is called from `_request_opens` on the **request path**, so a corrupt
state file would have taken a worker down on every page view. Before this
change it answered silently and wrongly, which is exactly how it went
unnoticed through seven phases.

**The change did not create the bug; it converted a silent wrong answer into a
loud one.** That is the better failure, and it is the second time this platform
has done that for gdash — the first was the LDAP module refusing to conflate a
wrong password with an unreachable directory.

## G7-12 — seven JSON readers indexed a decoded value without checking its shape

Fixing G7-11 exposed a bigger one. `read_state` also raised on `[1, 2, 3]` —
valid JSON that decodes fine and then raises on the first field read. A sweep
found the same defect in **every** remaining JSON reader:

| reader | what a wrong shape reached |
|---|---|
| `gdash_sched.read_state` | the scheduler and the request path |
| `gdash_users.load_users` | the login path |
| `gdash_authcfg.load_config` | the login path |
| `gdash_session_files.get` | `gdash_session.active`, on every request |
| `gdash_source_fixture` | a refresh |
| `gdash_refresh.load_profiles` | a refresh |
| `gdash_refresh_child` | the child process |

This is G6-15 again — the nine sites in the record validator — in the seven
files GDASH-6's adversarial pass did not reach, because that pass was aimed at
the record and these read gdash's *own* files. Which is the point worth
recording: **a file gdash writes and gdash reads is exactly the file nothing
else would notice had changed shape.** A full disk truncates it, an operator
edits it, an older build leaves a different shape behind.

All seven now check and fall back to something sane: no users rather than an
empty user list, no session rather than a broken one, no profiles rather than a
raise.

## G7-13 — the worker count is configuration now, and G6-7 is closed

`web.configure(sv, settings)` returns another declaration with deployment
settings merged in, so the head keeps its literals and the value still reaches
the runtime. gdash reads `GDASH_WORKERS` and passes it through; `run_workers.sh`
no longer copies `src/` to a scratch directory to rewrite a literal, which is
about forty lines and one whole class of confusion gone.

Two details from the update are worth keeping:

- **`app.options.workers = 4` was always possible**, and the reason to prefer
  `configure` is not capability but validation: `app.options.workesr = 4` is
  accepted in silence, creates a field nothing reads, and leaves the server on
  the declared value. That is the same failure shape as `chart.options` merging
  unknown keys (G7-5), and the same answer — refuse by name.
- **`workers: 0` now raises** rather than quietly serving single-process. gdash
  clamps a configured `0` up to `1`, because an operator who typed 0 meant one
  worker, not a dead server, and an environment variable is exactly where a 0
  arrives by accident.
