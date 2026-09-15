# GDASH-13 findings

## G13-1 — every non-ASCII currency symbol was double-encoded

`gdash_format._symbol` was written as:

```basic
if currency = "JPY" then
    return chr(194) + chr(165)
end if
```

`194, 165` are the two **UTF-8 bytes** of `¥`. `chr` takes a **codepoint**, so
`chr(194)` is `Â` (U+00C2). The result is two characters, which leave the
process as `c3 82 c2 a5`. Every JPY figure gdash has rendered read `Â¥1,234`;
every GBP one `Â£`; every EUR one `â‚¬`.

Measured, not inferred: `len(gdash_format.symbol_for("JPY"))` was 2. At the
platform, `chr(165)` is `¥` and `code("¥")` is 165, and the reference states
that `chr` and `len` count codepoints and never bytes.

**Thirteen phases, invisible, because `$` is ASCII.** USD is the only currency
that could not have shown it, and USD is all the fixtures had.

### The test asserted the bug

`test_format.bas` expected `chr(194) + chr(165) + "1,234"` — the implementation
spelled back at itself. A test written from the code rather than from the
answer cannot fail the way the code is wrong. The expected values are now
literal characters, with `len(...) = 1` beside each, which is the assertion
that could have caught this on the first day.

## G13-2 — a table rendered every money column at one scale, and the wrong one

`gdash_render.money_scale` returned ONE number for a whole dataset: the shared
scale if every money column agreed, `-2` if they did not. The `table` branch
read `-2` as "not a usable scale" and fell back to **2**.

On a multi-currency position report — USD at scale 2 beside JPY at scale 0, in
one dataset, which is what a position report is:

| stored | rendered | true value |
|---|---|---|
| 430000 | ¥4,300 | **¥430,000** |
| 12 | ¥0 | **¥12** |
| 1250000000 | ¥12,500,000 | **¥1,250,000,000** |

Every yen figure a hundred times small, in a table that looked entirely normal.
**A real balance of ¥12 rendered as ¥0** — a non-zero holding shown as nothing.

`_gdash_meta` has recorded the scale **per column** since GDASH-1 and
`gdash_store.money_columns` already returned the map. The renderer was the one
place collapsing it. CLAUDE.md states the invariant as *"per-column scale in
`_gdash_meta`"*; this was the code that did not honour it.

Now: a formatted column resolves to its own scale; an aliased column resolves
to the shared scale when every money column in reach agrees; and when it
cannot, the visual **refuses, naming the column**, instead of formatting at a
guess.

## G13-3 — one dataset's scale disabled currency formatting for all of them

`money_scale(db_path, attach)` read the money columns of the primary dataset
**and every attached sibling**. Attaching every sibling is what makes gdash's
cross-dataset joins work at all, so this meant any dashboard whose datasets
disagreed on money scale anywhere could not render a currency-formatted chart —
even for a visual that never touched the disagreeing dataset.

The `monthly` chart reads `ledger`, which has exactly one money column at scale
2, and refused with *"its dataset's money columns disagree on scale"* because
`positions` holds yen.

Fixed by the same change: the chart's scale is now the scale of **its value
channel**, looked up by that column's name, so `ledger.amount` is scale 2
whatever a sibling declares.

## G13-4 — GDASH-12's promotion produced a visual that could not render

`gdash_ask.draft_visual` set `format: "currency"` whenever the value channel
aggregated a money column, without asking whether a scale could be resolved for
it. On a multi-currency dashboard that promotes a visual which validates,
promotes, and then renders an error instead of a chart — found by whoever opens
the dashboard, not by whoever promoted it.

Mine, from the previous phase, and reachable only because this fixture exists.

Promotion now checks first, and when it declines it says why and what to do:
*"'total' holds money in minor units, and this dashboard's money columns do not
agree on a scale — so it will draw as raw minor units. Alias it to the money
column it comes from, or give the datasets one scale."* Aliased that way, it
resolves and the currency format comes back, which the suite asserts both ways.

## G13-5 — "the primary wins a column-name collision" was a guess with a test

`money_columns` is keyed by **column name** across the primary and every
attachment, and wrote `main` last so it won. `test_store.bas` asserted that as
a rule: *"the primary wins a column-name collision across schemas"*.

It is a reasonable guess and it is still only a guess. In `select amount from
fine`, the amount is the **sibling's**, and nothing in gdash can tell: SQLite
reports no provenance for a result column, and `sqlite.columns(db, sql)` — the
cross-repo ask that would give it — has not landed.

So "main wins" is right most of the time and **silently wrong** the rest, on the
one path where wrong money is indistinguishable from right money. A name that
means two scales now maps to `-2` and the renderer refuses, naming the column.
Same name, same scale, in two datasets is not a conflict and does not refuse.

**This reverses a decision that had a passing test.** It is recorded here rather
than made quietly, and it is in the brief's "owed to the maintainer".

## G13-6 — a mutation the fixture could not kill

"Table falls back to scale 2" — the defect exactly as it shipped — passed all
43 assertions of the new render suite. Both money columns in the fixture
resolve by name, so the refusal branch was never taken by anything.

Adding one table whose formatted column is an *aliased* money expression takes
it: the mutation then renders `$1,255,050.25` for the sum of dollars and yen —
a meaningless number, formatted with complete confidence. That is what the
branch exists to prevent, and nothing was testing it.

## G13-7 — two assertions were testing the directory, not the code

Two in `test_ask.bas` depended on the caseroot being empty: "a dashboard with no
data cannot be asked" (it asked about `sales`, which the same file stages later)
and "no models file configured is not an error" (it read the shared root, into
which the same file writes one). Both pass under `run_tests.sh`, which gives a
fresh caseroot — and both failed the moment a mutation run reused a scratch
directory.

An assertion that holds only because of where it sits in a file is an assertion
whose meaning can change without anyone editing it. The first now uses a
dashboard name nothing else touches; the second uses a root it owns. The file
is now idempotent: three runs into the same directory, 104 assertions, green.

## G13-8 — a guard that outlived its premise is not harmless

`gdash_shadow` walked the module directory recursively, because at gbasic
`159bc30` a `chart.bas` three directories below the loading file beat the
stdlib. That was reported; Matthew ruled on it; and as of the 2026-09-14 binary
a library below the loading file is **not used**, and is named in a warning
rather than dropped in silence.

For a few hours after that, gdash's guard was still refusing to start over files
the platform would never have loaded. That is not a harmless leftover:

- **It is a denial of service on a harmless file.** `src/vendor/web.bas` is a
  directory layout somebody actually has. gdash would have refused to start,
  citing a security risk that no longer existed.
- **A guard that fires where nothing is wrong is how a guard gets switched
  off.** The next person to meet a false refusal reaches for the flag that
  disables it, and then the real case is unguarded too.

So the narrowing was the work, not an optimisation. `shadows_in` reads one
directory.

The beside case is unchanged and is the one that matters for gdash: every
bare-name load lives in a module under `src/` — including the ones in
`gdash_server.bas` and the other entry **programs**, which sit in that same
directory. Measured on the new binary: a stray beside a program that does its
own bare load still wins, whatever the working directory is.

### The premise assertion paid for itself in a day

`tests/run_shadow.sh` asserted the platform's behaviour as well as gdash's,
which was written down at the time as "if the platform ever changes this rule,
gdash's suite reports that the guard is now unnecessary rather than leaving it
guarding against nothing".

It did exactly that: one red assertion, naming the deep case, on the first run
after the rebuild. A suite that only tested gdash would have stayed green while
the guard quietly became wrong.

### And the runner did not catch the mutation that reintroduced it

Reverting `shadows_in` to walk **one level** left `run_shadow.sh` green at
20/20, because its nested fixture sat **two** levels down. One level is both the
boundary and the realistic layout. It now plants at both depths, and the same
mutation fails two assertions.

`test_shadow.bas` did catch it, which is the only reason it was noticed — two
suites over one behaviour, disagreeing, is worth more than either alone.

## G13-9 — the units channel, and the clause that actually closes the failure

`nlq.plan` now takes `notes` (`nlq_gdash12_reply.md` §1). gdash needs no
`discovery` for it: it wrote these tables and recorded every kind and scale at
materialization, so `gdash_nlq.prompt_notes` generates the note from
`_gdash_meta` and the record's declared currency.

**Stating the factor is not enough.** A model told "amounts are in cents" can
still write `amount > 1000` for "over 1000 dollars", because nothing connects
the two statements. The note therefore spells out the literal:

```
orders.orders.amount: stored as INTEGER MINOR UNITS of USD at scale 2:
  1 USD is stored as 100, and the literal 1000 means 10.00 USD.
  Write comparisons and sums in minor units, never in whole USD.
```

Verified reaching the prompt against the repo's `stdlib/nlq.bas`.

A zero-decimal currency gets different words on purpose: "stored as minor
units" is an invitation to divide, and JPY is whole yen. Scale 0 says "stored as
a whole number of JPY, with no minor unit" and never mentions minor units.

## G13-10 — gdash made the exact mistake the fix it asked for creates

`plan` now refuses two different ways — ambiguity, and nothing grounded — both
as `ok: false` with `refused_because`. gdash's code, written when there was one
refusal, said **"that could mean more than one thing"** for both.

So the first run against the fixed library told someone whose dashboard has no
such data at all to choose between candidates that do not exist. Worse than the
bug that was fixed, in the sense that the old failure was expensive and this one
is misleading.

`kind` is the discriminator and it was there; nothing warned a caller written
against the one-refusal shape. `_refusal_words` now reads it, and is tested on
synthetic plan values rather than through the library so the assertion holds
whichever version is installed. Sent back as a suggested line in the
walkthrough.

## G13-11 — a consumer cannot feature-detect a library option except by trying

An older `nlq` raises on an unknown option — correctly; that is what `_options`
is for. But the stdlib installs separately from the interpreter and the two move
apart routinely: the binary carrying the shadowing change was installed while
`nlq.bas` was four days behind, which is how this was met.

So gdash tries `plan` with `notes` and falls back without them **once**, and the
draft carries `units_told`. The fallback is not silent: the CLI and the ask page
both say the model was not told what the money columns mean, because a silent
fallback would hide exactly the hazard the notes exist to close.

## G13-12 — `nothing` is a keyword

`nothing = false` is a parse error; SQL NULL maps to `nothing` in gBASIC. The
error named the line, which is the good kind of failure. Recorded because the
variable name is the obvious one to reach for and the word does not appear in
gdash's own vocabulary anywhere else.
