# Contribution to the NLQ library, from gdash

For the gbasic session, written from gdash's side because CLAUDE.md forbids
editing that repo from here. Copy what is useful.

gdash is the first application that will consume this library, and it is an
unusual consumer: it already knows its schema exactly instead of inferring it.
That makes it a good early target and a slightly misleading one, so the useful
things gdash can say are mostly about the ways it will break the obvious
design.

Ordered by what I would fix first.

---

## 1. The money trap, which is silent and gets the demo wrong

gdash materializes money as **INTEGER minor units**, with the scale recorded
per column in a `_gdash_meta` table inside the dataset file (design §4). A
schema reader sees this:

```
CREATE TABLE "orders" ("region" TEXT, "month" TEXT, "amount" INTEGER)
```

and the rows look like this:

```
('west', '2026-01', 125075)
```

So, against real staged gdash data, "how many orders over $1000":

```
select count(*) from orders where amount > 1000        ->  6      WRONG
select count(*) from orders where amount > 1000*100    ->  2      right
```

**Both queries run. Neither errors. Both return a plausible small integer.**
Nothing downstream can tell them apart, and in a dashboard a wrong number looks
exactly like a right one.

`_gdash_meta` has the answer — `('amount', 'money', 2)` — but a text-to-SQL
layer that reads `sqlite_master` and not `_gdash_meta` will never see it. In a
core banking estate this is not an edge case; it is most of the columns anyone
will ask about, and it is the failure most likely to happen in front of an
investor.

**Ask:** scale must be part of the contract, not a post-hoc correction. A
column description that can carry `{kind: money, scale: 2, currency: USD}`
should be a first-class input, and a query touching such a column without
honouring its scale should be a refusal, not an emission.

## 2. A trap gdash already fell into, that you will meet on day one

A gdash dataset file carries **its own** `_gdash_meta`. Visual queries run with
other datasets ATTACHed, and unqualified table names resolve across attached
schemas — that is how a cross-dataset join needs no prefix (gdash finding
G2-2).

But an unqualified read of `_gdash_meta` resolves silently to `main`
(gdash finding **G2-3**), which renders one dataset's money column at another
dataset's scale. Silently. gdash now qualifies every such read.

If the library reads metadata tables across an attached-schema database, it
will hit this exactly once and lose an afternoon. It is written down here so it
costs a paragraph instead.

## 3. gdash does not need discovery — it needs to be *told*

Most of what this library will work hard to infer, gdash already holds as
ground truth:

| fact | where gdash has it, exactly |
|---|---|
| column kinds and scales | `_gdash_meta`, written at materialization |
| which columns must stay exact | the record's `columns` block |
| dataset → dataset relationships | the record; joins are authored, not guessed |
| parameter dependency graph | derived from `:name` bindings in the SQL text |
| how stale each table is | per-dataset state, `data as of` |

**Ask:** let a caller *supply* a schema description rather than only pointing
the library at a database. If the only entry point is "discover this DSN", gdash
must throw away better information and let the library re-derive a worse
version of it. The discovery library and the NLQ library should meet at a
schema description that either can produce and NLQ consumes.

That interface is also what makes the two testable independently: discovery is
scored on whether it recovers the description; NLQ is scored on whether it
answers correctly *given* one.

## 4. Where generated SQL is allowed to land in gdash

A gdash record has two kinds of SQL and they are not interchangeable
(design §2):

- **Dataset queries** run against the outside source on a schedule. They take
  **no parameters, ever.**
- **Visual queries** run against the staged copy and are the only place
  parameters may appear, as `:name` bindings.

NLQ output belongs in the **visual** half. A generated query is a question
about data gdash already has, and it must not become a new fetch from a
production source because someone typed a sentence.

**Ask:** if the library emits parameters at all, let the caller declare whether
parameters are permitted, and have it refuse rather than inline literals when
they are not.

## 5. An answer without an as-of is a lie

gdash serves **stale-but-coherent** data by design: a dataset is a point-in-time
copy, a failed refresh leaves the previous copy untouched, and the page states
`data as of` per dataset because one line for a whole dashboard stops being
true the moment two datasets diverge.

"How many accounts opened today" against a dataset that last refreshed at 03:00
has a correct-looking answer and a wrong meaning. In banking that distinction
is the whole game.

**Ask:** the result should carry the staleness of what it read, or at minimum
the library should accept per-table as-of information and be able to say *"this
question needs fresher data than you have."* An NLQ layer that cannot say that
will confidently answer questions it cannot answer.

## 6. The verification problem, and the reframe I would build toward

The hard part is not generating SQL. It is that **nobody can tell whether a
generated query is right**, because a wrong number is indistinguishable from a
right one, and the person asking is precisely the person who could not write
the query themselves.

gdash's answer to trust everywhere else is not accuracy claims — it is
*visibility and durability*: the SQL is in the record, the data's age is on the
page, the version is pinned per viewer, and any two published versions can be
diffed.

So the integration I would build is **not** a chat box that returns a number.
It is: a question produces a **draft visual** — the generated SQL, the
assumptions it made, the `data as of` it would read, rendered as a real chart —
which a person can then **promote into the dashboard**, where it is reviewed,
versioned, diffed and audited like every other visual.

That reframes the library from *answer oracle* to *visual author*, and it is
better on every axis that matters:

- a wrong query is caught while it is still a draft, by someone who can read
  SQL, instead of in a meeting;
- the output is durable — the value of a good question is a dashboard that
  keeps answering it, not a number in a scrollback;
- it is a far better demonstration. "Natural language produced a reviewable,
  versioned dashboard visual with its SQL and its data lineage visible" is a
  much stronger claim than "the chatbot said 4.2 million", and it is the claim
  a technical audience will actually probe.

**Ask, concretely:** return the SQL, the assumptions, and a confidence or
refusal — as data, not prose. gdash can render all three. A library that
returns only a result set forces every consumer to trust it, and gdash's whole
architecture is built on not having to.

## 7. Refusal is a feature, and it needs a shape

The most useful thing this library can do in a banking estate is decline:
*"`balance` is a money column and your question compares it to a bare number",*
*"two tables have a column named `account_id` and they are not the same
thing", "this needs data fresher than the copy you have".*

**Ask:** make refusals structured and specific enough to show a user. gdash can
render a refusal usefully; it cannot render a wrong number usefully, because it
does not know it is wrong.

---

Happy to prototype the consuming side against a stub as soon as the schema
description shape is decided — that is the piece gdash depends on, and it is
the piece worth agreeing before either side builds much.
