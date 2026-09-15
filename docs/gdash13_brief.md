# GDASH-13 — money that is not dollars

## Why this phase exists

Every money number gdash has ever rendered has been US dollars, at scale 2, in
a dashboard whose datasets all agreed on that scale. The reference record is
one dataset of USD; the suite's fixtures are the same; GDASH-12's unit guard
was tested against JPY and four-decimal rates **as values**, never through the
renderer.

So a banking-shaped dashboard was built — the shape estateforge is generating —
and four things broke, three of them silently.

`dashboards/treasury/draft.json`, three datasets: `positions` (USD at scale 2
**and** JPY at scale 0, in one dataset, as a multi-currency position report
actually is), `ledger` (USD, with negatives and a value in the tens of
millions), `fx` (rates at scale 4).

## Step 0

### S0-1 — every non-ASCII currency symbol is double-encoded

```
gdash_format.currency("430000", 0, "JPY").text  ->  Â¥430,000     (len 9)
gdash_format.currency("125075", 2, "GBP").text  ->  Â£1,250.75
gdash_format.currency("125075", 2, "EUR").text  ->  â‚¬1,250.75
```

`_symbol` is written as `chr(194) + chr(165)` — the **UTF-8 bytes** of `¥`
supplied to a function that takes **codepoints**. `chr(194)` is `Â` (U+00C2).
The result is `Â¥`, two characters, which leaves the process as `c3 82 c2 a5`.

Confirmed at the platform: `chr(165)` is `¥`, `code("¥")` is 165, and the
reference says `chr` and `len` count codepoints and never bytes.

**Invisible for thirteen phases because `$` is ASCII.** USD is the only
currency that could not have shown this.

### S0-2 — a table renders every money column at one scale, and the wrong one

The positions table, rendered:

| account | usd_value | jpy_value | true value |
|---|---|---|---|
| ACC-0001 | $1,250,750.25 | ¥4,300 | **¥430,000** |
| ACC-0002 | -$90,425.10 | ¥0 | **¥12** |
| ACC-0004 | $88,000,000.00 | ¥12,500,000 | **¥1,250,000,000** |

Every JPY figure is wrong by a factor of a hundred, in a table that looks
entirely normal. **A real balance of ¥12 renders as ¥0.**

The cause is that `gdash_render.money_scale` returns ONE number for a whole
dataset. With columns at scale 2 and scale 0 it returns `-2` ("they disagree"),
and the table branch reads that as "not a usable scale" and falls back to **2**.
A silent default, on the one code path where being wrong is indistinguishable
from being right.

`_gdash_meta` has held the scale **per column** since GDASH-1, and
`gdash_store.money_columns` already returns the map. The renderer collapses it.
CLAUDE.md states the invariant as *"per-column scale in `_gdash_meta`"*; the
render path is the place that does not honour it.

### S0-3 — one dataset's scale disables currency formatting for all of them

```
visual 'monthly' formats as currency but its dataset's money columns disagree on scale
```

`monthly` reads `ledger`, which has exactly one money column, at scale 2. It
refuses anyway, because `money_scale` reads the money columns of the primary
dataset **and every attached sibling** — and `positions` is attached, because
attaching every sibling is what makes gdash's cross-dataset joins work at all.

So: any dashboard whose datasets disagree on money scale anywhere cannot render
a currency-formatted chart, even for a visual that never touches the
disagreeing dataset. The headline feature and the money formatter are in each
other's way.

### S0-4 — GDASH-12's promotion produces a visual that cannot render

`gdash_ask` sets `format: "currency"` on a promoted visual whenever the value
channel aggregates a money column. It does not ask whether the dataset can
supply a scale. On `positions` it produces a visual that validates, promotes,
and renders the S0-3 error.

Mine, from the previous phase, and caught only because this fixture exists.

## Scope

1. **`_symbol` takes codepoints.** One line per symbol.
2. **Scale becomes per column.** `money_columns` already has the map; the
   renderer uses it — for a table cell by the column's own name, and for a
   chart channel by the channel's column name.
3. **The remaining ambiguity fails loudly.** A result column that is NOT a
   money column of any dataset — an aliased aggregate, say — has no scale to
   look up. Where every money column in reach agrees, that answer is still
   right and is still used. Where they disagree, the visual is **refused with a
   message naming the column**, rather than formatted at a guess.
4. **`money_scale`'s attach-wide read** narrows to the datasets the visual
   actually names, so a sibling's scale cannot disable a visual that does not
   touch it.
5. **Promotion checks before it sets `format: "currency"`**, and the draft says
   why when it does not.
6. The treasury dashboard and its three fixtures become permanent, with
   end-to-end coverage, so "money that is not dollars" is a thing the suite
   renders on every run.

## Deliberately not built

- **A per-row currency.** Real core banking stores `amount` beside
  `currency_code` and lets the scale vary by row. gdash's model is one scale
  per column, which cannot express it — the fixture therefore uses one column
  per currency, which is what a position report does anyway. Naming this as a
  limitation is the deliverable; changing the storage model is not this phase.
- Currency conversion, rate application, or anything that does arithmetic
  across currencies.
- New symbols beyond the four `_symbol` names. The fallback is `CHF 1,234.00`,
  which is correct and unambiguous for the other 174.

## Owed to the maintainer

Design §4 says money materializes as minor units with a per-column scale. It
does not say what the RENDERER does when one result set spans two scales, and
the answer it has been giving is "assume 2". This phase makes it refuse
instead. If the intended answer was something else — a per-visual scale
declaration, say — that is the maintainer's ruling and this is the finding.
