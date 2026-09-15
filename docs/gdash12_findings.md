# GDASH-12 findings

Numbered from G12-1. The step-0 findings are in `gdash12_brief.md`; these are
what building the integration turned up.

## G12-1 — the shadowing rule is the LOADING FILE's own directory

**Superseded in part, and that is the finding's best outcome.** What follows is
what was measured at gbasic `159bc30` and reported. Matthew ruled on it, and as
of the 2026-09-14 binary **a library below the loading file is no longer used**
— it is named in a warning instead. The `beside` row is unchanged. `gdash_shadow`
narrowed to one directory; see G13-8 for why that mattered rather than being
merely tidy.

S0-2 as first written said "a file in the current working directory". That is
wrong, in both directions, and the correction matters both ways. Measured at
gbasic `159bc30`, the same `chart.bas` in four places:

| where | result |
|---|---|
| the process's working directory | stdlib wins — no effect |
| beside the program | stdlib wins |
| beside the library issuing `load chart` | **stray wins** |
| three directories below it | **stray wins** |

Narrower than reported (not any directory a caller happens to be in) and wider
(any depth beneath the loading file). The second half is what makes a directory
listing an inadequate review, and it is why `gdash_shadow` walks rather than
lists.

Corrected in `gdash12_platform_report_nlq.md` §2 — and the maintainer did act
on it.

## G12-2 — a guard cannot run before the load it guards

Loads resolve before the program body runs: a `print` on the line above a
failing `load` does not reach stdout. So no gBASIC program can inspect its own
module directory *before* a shadow is loaded.

What makes the guard sufficient anyway is that a library body **defines**
rather than **runs** — a top-level `print` inside `library evil ... end
library` produced nothing at load. A shadow is therefore inert until something
calls it, and gdash refuses before calling anything. Both measured by probe,
not reasoned from the source.

## G12-3 — every ATTACH is now read-only, and it costs nothing

`file:<path>?mode=ro` works through `attach database` and genuinely refuses
writes. Nothing in gdash is lost by it: a dataset file is written by
`materialize` through its own direct connection and made visible by a single
rename, so no query gdash runs — visual, describe, sample, or generated — has
any business writing through an attachment.

It matters most for the last kind. `nlq.check_sql` is the gate that refuses a
generated `delete`; this is what makes a gap in that gate harmless rather than
destructive. Asserted by going around the gate: with the check bypassed, SQLite
itself refuses and the rows are still there.

Three characters are percent-encoded (`%`, `#`, `?`) and there is **no
fallback** to a writable attach. A file gdash cannot open read-only is a file
gdash reports.

## G12-4 — the two tiers name tables differently, and promotion is the seam

The NLQ catalog attaches every dataset under its own name, so a table is
`orders.orders`. That is what closed G2-3 — each `_gdash_meta` is reached
through its own schema, so no dataset can be read at another's scale. A visual
query opens its named dataset directly and attaches only the **siblings**, so
the same table is plain `orders` and `orders.orders` does not resolve at all.

A promoted query is rewritten across that line: `D . D` becomes `D`, so
`orders.orders` becomes `orders` and `orders.orders.amount` becomes
`orders.amount`, which is correct in the visual form. A character scan, not a
token rebuild — the tokenizer drops whitespace, and this text goes into a
record a person maintains.

**Reusing `gdash_nlq._is_ident_char` made it silently wrong.** That predicate
counts `.` as part of an identifier, deliberately, so that `a.b.c` is one token
for the unit guard. Here the dot is the thing being matched, so a trailing
`.amount` read as "still inside a name" and three-part columns were left alone.
Caught by probe before it reached a test, which is the only reason it is a
finding rather than a bug.

## G12-5 — the primary dataset is the one the QUERY names, not the one the grounding names

"total by region" grounds both `orders` and `regions`, because both have a
region column; the SQL the model wrote touches only `orders`. Taking the first
grounded table gave a visual whose `dataset` was `regions` and whose query
never mentions it.

That visual **renders**. Every other dataset is attached, so the query works,
and nothing downstream would ever have complained. The first version of the
test did not catch it either: `regions` and `orders` both sort such that the
obvious wrong implementation passed. It took a question about the *second*
dataset to separate them.

## G12-6 — money, one step later than step 0

An aggregate of minor units is still minor units. A promoted `sum(amount) as
total` renders 215100 where a person expects $2,151.00 — the step-0 failure
arriving in the chart instead of the answer.

gdash already renders it correctly given `format: "currency"`, so promotion
sets that — **narrowly**: an aggregate directly over a money column, or the
column itself. Not `count(*)`, not `amount / 100`, and **not `count(amount)`**,
which counts rows rather than adding money and is separated from `sum(amount)`
by the aggregate's name alone. Marking a count as currency would render 3 as
$0.03: a wrong answer produced by the machinery meant to prevent wrong answers.

Verified end to end in the browser: the promoted chart's axis reads $1,000.00
to $4,000.00.

## G12-7 — `nlq.plan` returns `ok` for a question the catalog cannot answer

`plan` refuses on **ambiguity** and not on **unanswerability**. A question with
nothing to ground against comes back `ok: true` with a prompt naming no tables:

```
question:  what is the share price?
ground:    tables [] , ambiguous 0 , unresolved ["share","price"]
plan.ok:   true
```

Five such questions out of twenty all planned `ok`. Every one would have been
sent to a model, paid for, and then refused by `check_sql` for naming a table
nobody offered — safe, expensive, and reported as a SQL problem when it was
never about SQL.

`nlq.check_answerable(g)` is the library's own rule and catches all five. It
raises rather than returning, so gdash catches it and turns it into the same
kind of value as every other stop, at stage `ground`, before the wire.

Reported as `gdash12_platform_report_nlq.md` §3, as a question about the
default rather than a missing capability.

## G12-8 — the corpus scored 20/20 with the thing it measures removed

The first version of `tests/nlq_corpus.bas` called `nlq.plan` and
`nlq.check_answerable` directly. That measures the **library**. With gdash's
own answerability check mutated away, it still scored 20/20.

It now runs every question through `gdash_ask.ask` with a model double, and the
same mutation reports 0/5 and exits 1. A corpus that cannot fail when the thing
it is about is removed is measuring something else.

This is the third time in two phases that a test has needed to be tested. The
other two were the nlq suite crashing instead of failing, and the end-to-end
needles that also appear in the stylesheet.

## G12-9 — a test that crashes hides every test after it, again

Two assertions in the ask suite raised rather than failed when a mutation
removed what they were reading — `record["visuals"][id]["sql"]` when `visuals`
is empty, and `tabs[0]["layout"]["vert"][0]` when nothing was placed. The run
died at that line and every later assertion went unreported.

Same hazard as the nlq suite in the previous increment, and the same fix:
indexed reads go through accessors that return a legible absence
(`"(not promoted)"`, `"(nothing on the first tab)"`). The mutations then report
4 and 1 failures instead of a stack trace.

## G12-10 — the login-throttle assertion flaked in BOTH directions

Previously: a fifth attempt asserted as a second 429 came back 401 about one
run in three. After that was reduced to four attempts: the fourth came back 401
under a heavier suite.

Same cause, and not a defect. The wait after the third failure is **one
second**, so an attempt arriving more than a second later has genuinely waited
and is genuinely entitled to try. Two curl processes plus a `/whoami` round
trip per attempt can spend that second on their own.

All four attempts now go through **one curl process on one connection** with no
round trip between them. That is legitimate rather than merely convenient: a
failed login does not regenerate the session, so one CSRF token is good for all
four. The schedule itself stays pinned exactly in `test_throttle.bas` against
an injected clock, where it costs no wall time and cannot race.

## G12-11 — the namespace audit refused three names on sight

`gdash_shadow` was first written with `scan`, `check` and `module_dir`.
`gdash_sql`, `gdash_record` and `gdash_paths` already define all three, and the
audit reported every one. Harmless under own-library-first resolution since
`d08409f`, and still wrong to leave: a name defined twice is a name no caller
can write bare.

Worth recording because the audit is the only thing that sees this — the
platform's own warning is call-triggered, so two libraries sharing a name stay
silent until somebody writes the first unqualified call.
