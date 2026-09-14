# Report to the gbasic session — two findings from gdash's NLQ step 0

**From:** gdash, GDASH-12 step 0
**Measured against:** `stdlib/nlq.bas` at `159bc30`, copied into a probe
directory (see finding 2 for why that works), against a real gdash staged
SQLite file.

`nlq_for_gdash.md` asks for three things back. This is the third — *"a question
that was answered confidently and wrongly"* — plus one found on the way to it.

---

## 1. There is no channel for a column's UNITS, and gdash is full of them

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

Found while establishing that `nlq` was not installed, and it is the more
general finding.

**Corrected since first sending, and the correction matters both ways.** This
section originally said *"a file in the working directory"*. That is wrong. The
directory that wins is the one holding **the source file that issues the
`load`** — `dirname(current_import_path)`, falling back to the root program —
and it is searched **recursively**. Measured at `159bc30`:

| where the stray `chart.bas` is | result |
| --- | --- |
| the process's working directory | stdlib wins — no effect |
| beside the *program* that loads the library that loads `chart` | stdlib wins |
| beside the *library* issuing `load chart` | **stray wins** |
| three directories *below* that library | **stray wins** |

So the exposure is narrower than reported (not any directory a caller happens
to be in) and wider (any depth beneath the loading file, not just next to it).
The second half is the one that makes a directory listing an inadequate review.

```
$ cat lib/deep/deeper/chart.bas
library chart
    function who_am_i()
        return "FAKE three directories down"
    end function
end library

$ gbasic prog.bas
warning: additional library 'chart' match ignored: /usr/local/share/gbasic/stdlib/chart.bas
FAKE three directories down
```

The local file **wins**; the real library is the one reported as "ignored".

The warning is correct and it is on stderr, which is where a service's output
goes to be unread. For gdash the exposed names are `chart`, `crypto`, `ldap`,
`odbc`, `pg`, `sqlite`, `web` — `crypto` hashes every password and mints every
session secret, and `web` is the server. Every one of gdash's bare loads lives
in a module under `src/`, installed to the libdir, so for gdash it is one
directory tree rather than an inherited working directory.

Two observations rather than a demand, since the precedence is plainly
deliberate for development:

- **The asymmetry is the surprising part.** A library defining a name another
  library already defines is refused at parse time (`f21486e`), and a function
  shadowing a built-in gets a note. A *whole stdlib library* being replaced by
  a file several directories below the one that asked for it is the quietest of
  the three, and the highest-consequence.
- **If precedence stays, the notice may not want to be a warning** — at least
  for the security-carrying modules. A flag to refuse (`--no-local-libraries`,
  or refusing a match found below the loading file rather than beside it) would
  let a daemon opt into the strict reading.

Two things measured while building the guard, offered because they bear on any
ruling and are cheaper to read than to rediscover:

- **A symlink loop under the search root does not hang it.** `lib/loop -> lib`
  terminated promptly rather than recursing forever — presumably on path
  length. Fine as it stands; worth a deliberate cap if the search ever changes.
- **Loads resolve before the program body runs.** A `print` on the line above a
  `load` does not reach stdout when the load fails, so no program can inspect
  its own module directory *before* a shadow is loaded. What saves it is that a
  gBASIC library body **defines** rather than **runs**: a top-level `print`
  inside `library evil ... end library` produced nothing at load. So a shadow
  is inert until called, and an application guard placed first in `main` is
  sufficient. Both confirmed by probe, not by reading source.

gdash refuses to start if one of its seven names is shadowed, regardless of
what the platform decides — `src/gdash_shadow.bas`, enforced by all four entry
points, 34 in-process assertions and 17 across processes. `tests/run_shadow.sh`
asserts the **premise** as well as the guard, so if the platform ever changes
this rule gdash's suite reports that the guard is now unnecessary rather than
leaving it guarding against nothing.

---

## Not a finding, but worth having on the record

Everything else in step 0 behaved as `nlq_for_gdash.md` says it does.
`unresolved` named the words that matched nothing, a synonym closed the gap,
`interpret` refused an unqualified `from orders` because the grounding offered
`main.orders` — correctly, and it caught a real mistake of mine in doing so —
and every refusal arrived as a value that could be printed. The four-step split
is comfortable to build against.

The recall and refusal-rate numbers you asked for (item 1) need the integration
built, which needs the install. They will follow.
