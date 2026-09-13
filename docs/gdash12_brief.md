# GDASH-12 — natural-language questions, over a dashboard's own data

## Why now

gBASIC ships `stdlib/nlq.bas` and `docs/nlq_for_gdash.md` is written to this
session. gdash is the library's first consumer.

The integration this phase builds is **not** a chat box that returns a number.
It is the shape argued in `nlq_contribution.md` §6 and unchanged by anything in
step 0: a question produces a **draft visual** — the generated SQL, the
assumptions behind it, the `data as of` it read, rendered as a real chart —
which a person then promotes into the dashboard, where it is versioned, diffed
and audited like every other visual. A wrong query is then caught while it is
still a draft, by somebody who can read SQL.

## Step 0

Three verifications, run before any design. **Two failed**, and the second is
the reason this brief stops here.

### S0-1 — `nlq` was not installed — **RESOLVED**

The maintainer re-ran `make install` in the gbasic repo. Both libraries now
load from a clean directory at the repo's own sizes (`nlq.bas` 63 755,
`discovery.bas` 104 247), and gdash's full suite is green on the newly
installed platform — 31 suites, checked because the platform moved, which is
what the change detector is for.

S0-3 was re-measured against the **installed** library, with no local copy in
the directory. It stands unchanged: 6 returned, 2 correct.

The original finding follows, since the install step is a real one and the
next person to arrive at a fresh machine will meet it.

### S0-1 (as found) — `nlq` is not installed; gdash cannot load it

```
$ gbasic -e 'load nlq'
runtime error: library not found: nlq
```

`nlq.bas` exists only in the gbasic working tree. The installed stdlib has no
copy, and its `discovery.bas` is three days and 11 KB behind the repo's:

```
/usr/local/share/gbasic/stdlib/discovery.bas   93 715   Sep 10 19:48
~/development/gbasic/stdlib/discovery.bas     104 247   Sep 13 09:49
~/development/gbasic/stdlib/nlq.bas            63 755   Sep 13 13:25   (not installed)
```

gdash loads stdlib modules by bare name, which resolves against the *installed*
tree. This is the same trap that made the chart work appear broken in GDASH-10,
and it is why the suite carries a platform-change detector.

**Not a defect — an install step**, and the maintainer's to run.

Everything measured below was therefore run against a **copy** of
`stdlib/nlq.bas` from the gbasic working tree at `159bc30`, placed in the
probe's working directory. Which works, for the reason in S0-2.

### S0-2 — a stray `.bas` in the working directory silently replaces a stdlib library

Found while establishing S0-1, and worth more attention than the thing that
found it. A file named `chart.bas` in the current directory:

```
warning: additional library 'chart' match ignored: /usr/local/share/gbasic/stdlib/chart.bas
I am not the real chart library
```

The local file **wins**. The real library is the one "ignored", and the notice
is a warning on stderr — which a service's stderr goes to a log nobody reads at
the moment it matters.

gdash loads seven libraries by bare name:

```
chart   crypto   ldap   odbc   pg   sqlite   web
```

`crypto` hashes every password and mints every session secret. `web` is the
server. Neither the repository root nor an installed `@LIBDIR@` holds a
colliding file today, and `scripts/gdash-server.in` inherits whatever working
directory the caller had — so the exposure is real, currently unrealised, and
invisible if it ever is realised.

Reported in `gdash12_platform_report_nlq.md`. gdash should also refuse to start
when one of its seven names is shadowed, which is cheap and fails closed.

### S0-3 — the money hazard is real, unaddressed, and silent

`nlq_contribution.md` §1 predicted this before the library existed. Step 0
measured it against **real gdash staged data**, through the library's whole
path, at `159bc30`:

```
plan ok:       true
interpret ok:  true
problems:      0

ANSWER RETURNED: 6
TRUE ANSWER:     2
```

The question was *"how many orders were over 1000 dollars?"*. gdash stages
money as INTEGER minor units, so the model is shown:

```
main.orders(region, month, amount)
main.orders.amount in (125075, 110000, 90025)

Question: how many orders were over 1000 dollars?
```

Nothing in that prompt says those integers are cents. The model writes
`amount > 1000`, `check_sql` passes it — correctly, it is read-only and every
name is grounded — and `settle` returns a plausible integer that is wrong.

**There is no channel to fix it.** `discovery.annotate` accepts a `means` note,
and `means` appears in `nlq.bas` exactly once, inside `check_literals`. It never
reaches the prompt. `nlq.prompt`'s options are `budget_tokens`,
`chars_per_token`, `dialect`, `exemplars` — none carries a unit. Vocabulary
shows *values*, exemplars show *format*; neither can say *scale*.

gdash knows the scale exactly, per column, in `_gdash_meta`. It is one of the
few consumers that could supply this without a human typing anything, and there
is nowhere to put it.

This is precisely item 3 on `nlq_for_gdash.md`'s own "what would help most,
sent back" list — *a question answered confidently and wrongly* — so it goes
back before gdash builds on top of it.

## Blocked, and on what

1. **Install the platform** (S0-1). Until `nlq` is installed, gdash cannot load
   it outside a probe directory, and no suite can exercise the integration.
2. **A per-column note that reaches the prompt** (S0-3), or a ruling that gdash
   should work around it. Building the integration first would mean shipping a
   feature whose first demo question about money is wrong.

Neither is large. Both are upstream of design, which is why this brief stops
rather than working around them.

## Built so far

- `gdash_store.describe_datasets` / `sample_column` — a **cross-dataset read
  that attaches every dataset under its own name**, so a catalog names tables
  one way (`<dataset>.<dataset>`) rather than `main.<primary>` for one and its
  own name for the rest. It closes **G2-3** by construction: each `_gdash_meta`
  is reached through its own schema, so no dataset can be read at another's
  scale.
- `gdash_nlq.catalog` / `scaled_columns` / `attach_for` — gdash's own account
  of its data. No `discovery.scan`: gdash wrote these tables and recorded every
  kind and scale at materialization, which is better than a scan can recover.
- `gdash_nlq.unit_notes` — **the unit guard**, the part only gdash can write.
  39 assertions, five mutations, all caught.

### A note on `discovery`

gdash does not load it and will not, so it is not in the namespace audit. Worth
recording that if it ever does, two names collide: `scan` (with `gdash_sql`)
and `explain` (with `gdash_auth_ldap`). Harmless under the platform's
own-library-first resolution since `d08409f`, but it would need accepting with
a reason rather than discovering by surprise.

## Still to build

- The model wiring — `plan` → call → `interpret` → run → `settle` — behind a
  seam, the way `gdash_auth_ldap` keeps `ldap` behind `wire`.
- The draft visual: generated SQL, assumptions, `data as of`, unit notes,
  rendered as a real chart and promotable into the dashboard.
- The **shadowing refusal** from S0-2.
- The recall and refusal-rate numbers `nlq_for_gdash.md` asks for, which need
  all of the above.
