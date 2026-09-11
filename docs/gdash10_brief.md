# GDASH-10 — Chart follow-through: phase brief

**Status:** COMPLETE. All five §5 criteria met, verified against the
INSTALLED library. Findings in `gdash10_findings.md`; DONE note in §7.
**Narrows:** the deferred scope of GDASH-7 — §2.5, and the two limits its DONE
note recorded as waiting on the platform.
**Authority:** `gdash_design.md` outranks this brief.

---

## 1. What changed underneath

All four items in gdash's chart report were addressed. Verified against the
repo copy of the library, not read in the commit message:

| asked | delivered | verified |
|---|---|---|
| a categorical x draws nothing | ordinal x on `line`, `area`, `scatter`, at `bar`'s band centres | a categorical line draws the same number of marks as a numeric one |
| axis labels cannot be formatted | `x_prefix`/`x_suffix`/`x_decimals`/`x_scale` and the `y_` set | `y_prefix` reaches a tick; `y_scale: 100` with `y_suffix: "%"` renders a percentage |
| no mark carries an identifier | `mark_keys: true` adds `data-series`/`data-key` to data marks only | present when asked, absent by default, and never on a legend swatch |
| an unknown option is ignored | refused by name, with a near-miss hint, in `render` as well as `options` | `ylabel` reports "did you mean 'y_label'?" |

Two details in the delivery that gdash must not paper over:

- **A repeated category is allowed on a line and refused on a bar.** That is a
  deliberate asymmetry — a bar would have to invent a sum, a line invents
  nothing. gdash's own validation must not flatten it back into one rule.
- **`x_scale`/`y_scale` are display only** and move no geometry. That is what
  makes a fraction readable as a percentage without charting a different
  number, and it is also a way to lie with an axis, so gdash exposes it as the
  author's decision and says so.

## 2. Scope

### 2.1 Remove the refusal, and mean it

gdash refuses to render a `line` over a text x and tells the author to use
`bar`. That was a stopgap with its reason written into the message, and the
reason has gone. It goes, and the reference dashboard's `trend_by_region`
becomes a line again — it has been a bar since GDASH-7 purely because of this.

The test that pins the refusal is expected to go red. That was the design: it
is how gdash notices.

### 2.2 An axis that agrees with the numbers beside it

A visual already declares `format: "currency"` and a `currency`, or
`format: "percent"`. Those are enough to format the axis, so gdash derives it
rather than adding a second vocabulary the author has to keep in step:

- `currency` → the symbol as `y_prefix`, and `y_decimals` from the currency's
  minor units, which `gdash_format` already knows per ISO 4217.
- `percent` → `y_scale: 100` and `y_suffix: "%"`.
- `number` → separators, which is already the default.

**Derived, not configured.** A record that says a column is money should not
also have to say the axis is money; the second statement is the one that gets
forgotten and then disagrees.

### 2.3 Click a bar, publish a param

The deferred §2.5 of GDASH-7, unblocked. The record vocabulary was decided then
and is unchanged: a visual names which param a click publishes, and without it
a click does nothing.

- gdash sets `mark_keys: true` only on visuals that opted in, so every other
  chart's markup is byte-identical to today.
- The click reuses the slicer path exactly — `POST /d/{name}/params` — so no
  worker remembers anything and design §5 is untouched.
- `data-key` carries the category; that is what gets published.

**Tooltips are not in this phase.** They are pure client-side work on the same
attributes and they are not a dashboard's most-wanted feature; click-to-filter
is. Naming them here so their absence is a decision.

### 2.4 The typo refusal, checked from both ends

The library now refuses an unknown option by name. gdash already refuses its
own encoding keys at load time, which is the earlier and better place — an
author should not need a database to learn that `y_lable` is not a key. Nothing
to build; a test that both layers refuse, so neither is quietly removed later.

## 3. Construction rules

Unchanged, and additionally:

- **The suite must be re-run against the installed library, not the repo one.**
  Everything in §1 was verified against a path that gdash does not use. That is
  a fine way to unblock a brief and a poor way to close a phase.

## 4. Tests

- A categorical line **draws marks**, asserted as a count and not as `<svg>` —
  the assertion that failed to catch this for six phases.
- A line and a bar of the same frame **align**, which is the library's own
  load-bearing claim and worth an independent check from gdash's side.
- Each derived axis option reaches the SVG, asserted with it on and off.
- `mark_keys` appears only on visuals that opted in.
- A click publishes the param, and a visual that did not opt in publishes
  nothing.
- Both layers refuse `y_lable`.

## 5. Done means

1. The numeric-x refusal is gone and the reference dashboard has a line chart
   again.
2. A money axis reads `$5,339.65` and a percent axis reads `42%`.
3. Clicking a bar filters the dashboard, through the existing slicer path.
4. Every claim above is verified against the **installed** library.
5. Findings recorded; the DONE note names what was not built.

## 6. Deliberately not built

Tooltips (§2.3). Drill-through and cross-filtering between dashboards. Any
axis option gdash cannot derive from something the record already says —
adding `y_prefix` to the record would be a second place the format is
declared. Legend interaction. Zoom and pan, which need state a worker cannot
hold.

---

## 7. DONE note

**28 suites green** against the installed library, which is the version of that
sentence that counts: everything in §1 was first verified against a path gdash
does not use, and re-verified after `make install`.

All five §5 criteria met.

**Built:** the numeric-x refusal removed; a scatter that keeps every row and
three marks that refuse a repeat rather than aggregating silently; an axis
derived from the record's own `format` and `currency`; and click-to-publish,
blocked since GDASH-7 and now a wiring job exactly as its brief predicted.

**What the phase found**, all four of it in `gdash10_findings.md`:

- **A scatter lost points** behind the refusal that hid it — the refusal fired
  first on precisely the data that would have shown the bug.
- **The repeat detector collided with G6-16**, gdash's own finding, met from
  the other side.
- **The assertion audit refused two assertions I meant**, and moving them to
  where the shim is produced was better than the allowlist that would have
  kept them.
- **The reference dashboard had been drawing nothing for eight phases**, behind
  `contains(frag, "<svg")`.

**Deliberately not built** — §6 stands, and additionally:

- **Tooltips.** The attributes are there and it is client-side work, but
  click-to-filter is what a dashboard is asked for and a tooltip is what a
  dashboard is complimented on. Named so the absence is a decision.
- **`publishes` on a line or area.** Measured, not assumed: their marks carry
  no key because a path is a whole series. If the library ever puts a key on a
  point of a line, this is one line of validation.
- **Clearing a published param.** A click sets; nothing unsets except the
  slicer. A "show all" affordance is a control, not a chart feature, and
  inventing one here would put a second way to do it beside the `select` that
  already exists.
