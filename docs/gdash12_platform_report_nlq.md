# Report to the gbasic session — two findings from gdash's NLQ step 0

**From:** gdash, GDASH-12 step 0
**Measured against:** `stdlib/nlq.bas` at `159bc30`, copied into a probe
directory (see finding 2 for why that works), against a real gdash staged
SQLite file.

`nlq_for_gdash.md` asks for three things back. This is the third — *"a question
that was answered confidently and wrongly"* — plus one found on the way to it.

---

## 1. There is no channel for a column's UNITS, and gdash is full of them

**ANSWERED and shipped** — `nlq_gdash12_reply.md` §1. `nlq.plan` now takes
`notes`, and `prompt` renders only the notes for objects the grounding
selected. gdash needs no `discovery` for it: it wrote these tables and recorded
every kind and scale at materialization, so the note is **generated** from
`_gdash_meta` rather than annotated by hand.

Verified against the repo's `stdlib/nlq.bas` — the prompt now carries:

```
What the columns mean:
orders.orders.amount: stored as INTEGER MINOR UNITS of USD at scale 2:
  1 USD is stored as 100, and the literal 1000 means 10.00 USD.
  Write comparisons and sums in minor units, never in whole USD.
```

**The last clause is the one that matters**, and it is worth saying back
because it is not obvious: stating the factor is not enough. A model that knows
amounts are in cents can still write `amount > 1000` for "over 1000 dollars" if
nothing connects the two. So the note spells out what the literal 1000 would
mean *in that column* — the exact mistake step 0 measured.

Two notes from wiring it up:

- **A zero-decimal currency needs different words.** "Stored as minor units" is
  an invitation to divide, and JPY is whole yen. gdash emits "stored as a whole
  number of JPY, with no minor unit" for scale 0 and never mentions minor units
  there.
- **An older `nlq` raises on an unknown option**, so gdash tries with `notes`
  and falls back without them once, carrying `units_told` on the draft. That is
  not a complaint — it is the right behaviour for `_options` — but it does mean
  a consumer cannot feature-detect except by trying. The stdlib installs
  separately from the interpreter and the two move apart routinely, which is
  how this was met: the binary carrying finding 3 was installed while
  `nlq.bas` was not.

The original ask follows.

---

### Original report (as sent)

### The measurement

gdash materializes money as **INTEGER minor units**, with the scale recorded
per column in a `_gdash_meta` table inside the dataset file. A schema reader
sees `amount INTEGER`; the rows hold `125075` meaning `$1250.75`.

Question: *"how many orders were over 1000 dollars?"*

The prompt built for the model:

```
Tables:
main.orders(region, month, amount)
Column values:
main.orders.region in (west, east, north)
main.orders.amount in (125075, 110000, 90025)

Question: how many orders were over 1000 dollars?
```

The whole path, with the model's likely answer supplied:

```
plan ok:       true
interpret ok:  true
problems:      0

ANSWER RETURNED: 6
TRUE ANSWER:     2
```

`check_sql` passes it and is right to: the statement is read-only and every
identifier is grounded. The SQL is valid, the table is correct, the question is
answerable, and the number is wrong by a factor of a hundred.

### Why nothing available closes it

- **Vocabulary** shows which values a column holds. `125075` is a true value
  and says nothing about scale.
- **Exemplars** show what a value *looks like*. The longest instance of an
  integer is still an integer.
- **`discovery.annotate`'s `means`** is the natural home — and `means` occurs
  in `nlq.bas` exactly once, at line 247, inside `check_literals`. It never
  reaches `prompt`.
- **`nlq.prompt` options** are `budget_tokens`, `chars_per_token`, `dialect`,
  `exemplars`. None carries a unit.

A **synonym** does help one part: declaring `dollars` against the column moved
`dollar` out of `unresolved`. But grounding the right column and then comparing
it to the wrong magnitude is the failure, not a cure for it.

### Why this is worth a change rather than a workaround

This is the R2 shape your own brief names as the expensive one, and it arrives
by a different road: not two objects that both answer, but **one object that
answers in units nobody stated**. It is silent in exactly the way the 36%
warehouse case was silent, and on SQLite — the engine your brief already
singles out — there is no type error to catch it.

It is also unusually cheap to fix *for this consumer*, which is what makes it
worth raising rather than absorbing. gdash does not need a human to write the
note: `_gdash_meta` already holds `('amount', 'money', 2)` for every money
column, written at materialization. gdash can generate a per-column unit note
for free and hand it over. **There is simply nowhere to put it.**

### The ask, as small as I can make it

A per-column note that reaches the prompt. Something like:

```basic
nlq.prompt(g, cat, vocab, question, { notes: {
    "main.orders.amount": "stored in US cents; 125075 means 1250.75" } })
```

rendered into the `user` block beside the column values. That is enough. If you
would rather it live on the catalog so it serves documentation too — which is
the argument `annotate` already makes — then having `options_from` carry `means`
through to `prompt` achieves the same thing with no new surface at all, and
would be my preference.

A stronger version, if you want one: treat a stated unit as something
`check_sql` can test. A query comparing an annotated column to a bare numeric
literal whose magnitude is inconsistent with the stated scale is exactly the
class of error `check_literals` already catches for strings — *"said 1000
against a column stored in cents"* is the same sentence as *"said active, column
stores ACTIVE"*. I would not ask for that first; the note reaching the prompt is
the whole of the immediate need.

---

## 2. A stray `.bas` beside the LOADING FILE silently replaces a stdlib library

**ANSWERED and shipped** — `docs/nlq_gdash12_reply.md` §3, Matthew's ruling,
verified here on the 2026-09-14 binary. A library **beside** the loading file
may override; one **below** it may not, and the demoted file is named in a
warning rather than dropped in silence. The override warning now names the
winner first instead of only the loser.

Measured after the change, the same four placements:

| where a stray `chart.bas` sits | before | now |
| --- | --- | --- |
| the process's working directory | stdlib wins | unchanged |
| beside the *program* | stdlib wins | unchanged |
| beside the *file issuing the `load`* | **stray wins** | **stray wins** |
| any depth *below* that file | **stray wins** | **not used, and named** |

gdash's guard narrowed accordingly: `gdash_shadow` reads one directory and no
longer walks. It kept walking for a few hours after the platform stopped
needing it to, which was not harmless — refusing to start over a file the
platform will never load is a denial of service on a harmless file, and a guard
that fires where nothing is wrong is how a guard gets switched off.

`tests/run_shadow.sh` asserted the **premise** as well as the guard, so the
change arrived as one red assertion naming the deep case rather than as a
mystery. That was the whole point of asserting it, and it is now rewritten to
pin the new rule in both directions — beside wins, below does not, and gdash
keeps running over a file below.

The original report follows, since it is the measurement the ruling was made
from.

---

### Original report (as sent)

Found while establishing that `nlq` was not installed, and it is the more
general finding.

The directory that wins is the one holding **the source file that issues the
`load`** — `dirname(current_import_path)`, falling back to the root program —
and it was searched **recursively**. The local file **wins**; the real library
was the one reported as "ignored".

The warning is correct and it is on stderr, which is where a service's output
goes to be unread. For gdash the exposed names are `chart`, `crypto`, `ldap`,
`odbc`, `pg`, `sqlite`, `web` — `crypto` hashes every password and mints every
session secret, and `web` is the server.

Two observations rather than a demand:

- **The asymmetry is the surprising part.** A library defining a name another
  library already defines is refused at parse time (`f21486e`), and a function
  shadowing a built-in gets a note. A *whole stdlib library* being replaced was
  the quietest of the three, and the highest-consequence. *(This is what made
  the case, per the reply.)*
- **If precedence stays, the notice may not want to be a warning.** A flag to
  refuse (`--no-local-libraries`) would let a daemon opt into the strict
  reading. *(Considered and not built: narrowing the search helps everyone,
  where a flag helps only those who know to ask for it. The right call.)*

Two things measured while building the guard, which still hold:

- **A symlink loop under the search root does not hang it.** `lib/loop -> lib`
  terminated promptly rather than recursing forever.
- **Loads resolve before the program body runs.** A `print` on the line above a
  `load` does not reach stdout when the load fails, so no program can inspect
  its own module directory *before* a shadow is loaded. What saves it is that a
  gBASIC library body **defines** rather than **runs**: a top-level `print`
  inside `library evil ... end library` produced nothing at load. So a shadow is
  inert until called, and an application guard placed first in `main` is
  sufficient.

---

## 3. `plan` returns `ok` for a question the catalog cannot answer at all

**ANSWERED and shipped** — `nlq_gdash12_reply.md` §2, gdash's option 1.
`plan.ok` now means **worth asking a model**, and `refused_because` carries
`{ kind: "nothing_grounded", candidates: [...] }` with the words that reached
nothing. `check_answerable` stays between `plan` and the wire as belt and
braces, per the reply.

**And gdash immediately made the mistake the fix creates**, which is worth
sending back because the next consumer will make it too. `plan` now refuses two
different ways, both as `ok: false` with `refused_because`, and gdash's code
said "that could mean more than one thing" for both — telling someone whose
dashboard has no such data at all to pick between candidates that do not exist.
The `kind` field is the fix and it is there; nothing warns a caller who was
written against the one-refusal shape. A sentence in the walkthrough saying
"read `kind`; there are two" would have caught it.

The original report follows.

---

### Original report (as sent)

`nlq.plan` refuses on **ambiguity** — `g.ambiguous` non-empty, R1/R6 — and does
not refuse on **unanswerability**. A question with nothing to ground against
returns `ok: true` with a prompt naming no tables:

```
question:  what is the share price?
ground:    tables [] , ambiguous 0 , unresolved ["share","price"]
plan.ok:   true
```

Against a dashboard of `orders` and `regions`, five such questions — share
price, support tickets, profit margin, employee count, the chief executive —
all planned `ok`. A consumer that trusts `plan.ok` sends every one of them to a
model, pays for it, and gets back either a refusal or invented SQL, which
`check_sql` then refuses for `ungrounded_table`. It fails safe. It fails
**expensively**, and it reports a SQL problem for something that was never
about SQL.

---

## The numbers you asked for (item 1), as far as they go

Twenty questions against a dashboard of `orders(region, month, amount)` and
`regions(region, label, manager)`, through gdash's whole grounding path with no
model:

```
answerable questions grounded:  15/15
unanswerable questions refused:  5/5
vocabulary columns offered:      5
exemplar columns offered:        5
```

That is the grounding tier, and it is hermetic precisely because `nlq` performs
no I/O — which is worth saying back to you as a design result: the no-I/O rule
is what lets a consumer put recall in its ordinary test suite rather than in a
nightly job with a budget.

The **answer** tier — whole pipeline, real model, recall against known results
— is built and gated on `GDASH_NLQ_TEST=1`. It has not been run: it needs a key
and a decision to spend it, and both are the maintainer's.

---

## Not a finding, but worth having on the record

Everything else in step 0 behaved as `nlq_for_gdash.md` says it does.
`unresolved` named the words that matched nothing, a synonym closed the gap,
`interpret` refused an unqualified `from orders` because the grounding offered
`main.orders` — correctly, and it caught a real mistake of mine in doing so —
and every refusal arrived as a value that could be printed. The four-step split
is comfortable to build against.

The recall and refusal-rate numbers you asked for (item 1) are above, for the
grounding tier. The answer tier is built and waiting on a key.
