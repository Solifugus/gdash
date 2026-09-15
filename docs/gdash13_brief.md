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

---

## DONE

Delivered. `docs/gdash13_findings.md` has the detail.

- **`_symbol` takes codepoints.** `¥`, `£`, `€` are one character each, which
  the suite asserts with `len` rather than by spelling the bytes back.
- **Scale is per column.** `gdash_render.scale_of(cols, column)`: the column's
  own scale, else the shared scale when every money column in reach agrees,
  else a refusal naming the column and saying what to change.
- **`money_columns` records conflict** instead of letting `main` win a
  column-name collision — a reversal of a tested decision, recorded in G13-5.
- **Promotion checks before it formats**, and says why when it declines.
- **`dashboards/treasury/draft.json` and three `bank_*` fixtures are
  permanent**, rendered over HTTP on every run: USD at scale 2 and JPY at
  scale 0 in one dataset, rates at scale 4, a negative balance, ¥12, and
  $88,000,000.00.

Suite: 35 suites, 0 failed — e2e 253, render 45, ask 104, store 55, format 58.
ODBC 12 and FHS 22 re-run green.

### Deliberately not built

- **A per-row currency.** Real core banking stores `amount` beside
  `currency_code` and lets scale vary by row; gdash's model is one scale per
  column and cannot express it. The fixture uses one column per currency, which
  is what a position report does anyway. Naming the limitation was the
  deliverable.
- Currency conversion or any arithmetic across currencies. `fx` is in the
  fixture as a four-decimal non-currency money column, not as a rate anyone
  applies.
- Symbols beyond the four. `CHF 1,234.00` is correct and unambiguous for the
  other 174.
- A per-visual scale declaration in the record format. That is the maintainer's
  ruling to make; the brief says so.

### Added after the platform answered

`gdash_shadow` narrowed from a recursive walk to one directory, because the
library-shadowing rule narrowed: beside the loading file still overrides, below
it no longer does (`nlq_gdash12_reply.md` §3). The premise assertion in
`tests/run_shadow.sh` went red naming the deep case, which is what asserting a
premise is for. G13-8 has the account, including why leaving the wider guard in
place would have been a defect rather than a leftover.

### Also delivered after the platform answered

- **The units channel** (`nlq_gdash12_reply.md` §1). `gdash_nlq.prompt_notes`
  generates a per-column note from `_gdash_meta` and the record's currency, and
  `gdash_ask` passes it to `nlq.plan`. The model is now told what the integers
  mean **before** it writes, rather than the reader being told afterwards.
  G13-9 has the note text and why its last clause is the load-bearing one.
- **Two refusals, two messages** (§2). `plan` now refuses both for ambiguity
  and for nothing-grounded, and gdash said the ambiguity words for both on its
  first run — G13-10.
- **A fallback for an older `nlq`**, with `units_told` on the draft so it is
  never silent — G13-11.

### Owed to the maintainer

Design §4 says money materializes as minor units with a per-column scale. It
does not say what the **renderer** does when one result set spans two scales,
and the answer it had been giving was "assume 2". It now refuses. If the
intended answer was a per-visual scale declaration, that is a record-format
change and a ruling, not a phase's to make.

The same sentence covers G13-5: "the primary wins a column-name collision" was
a decision with a passing test, and this phase reversed it on the grounds that
it can only be silently wrong. Both are stated rather than assumed.
