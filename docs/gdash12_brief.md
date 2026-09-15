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
probe's own directory, which is where its `load nlq` resolves from --
for the reason in S0-2.

### S0-2 — a stray `.bas` beside the loading file replaces a stdlib library — **GUARDED**

Found while establishing S0-1, and worth more attention than the thing that
found it.

**The first statement of this finding was wrong and has been corrected.** It
said *"a file in the current working directory"*. The directory that wins is the
one holding **the source file that issues the `load`**.

**And the rule then narrowed under us, which is the good kind of narrowing.**
Measured at `159bc30`, a file at any depth below the loading file also won. That
was reported; Matthew ruled on it; and as of the 2026-09-14 binary a library
below the loading file is **not used, and named in a warning**:

| where the stray file is | at 159bc30 | now |
| --- | --- | --- |
| the process's working directory | stdlib wins | unchanged |
| beside the program | stdlib wins | unchanged |
| beside the file issuing `load chart` | **stray wins** | **stray wins** |
| any depth below it | **stray wins** | **not used, and named** |

So the exposure is one directory, not a tree. The guard narrowed with it —
`gdash_shadow` reads one directory and no longer walks — because refusing to
start over a file the platform will never load is a denial of service on a
harmless file.

The beside case is unchanged and is the realistic one for gdash: every bare-name
load lives in a module under `src/`, including the ones in the entry *programs*,
which sit in that same directory. Measured: a stray beside a program that does
its own bare load wins too, whatever the working directory is.

```
warning: additional library 'chart' match ignored: /usr/local/share/gbasic/stdlib/chart.bas
FAKE three directories down
```

The local file **wins**. The real library is the one "ignored", and the notice
is a warning on stderr — which for a service goes to a log nobody reads at the
moment it matters.

gdash loads seven libraries by bare name:

```
chart   crypto   ldap   odbc   pg   sqlite   web
```

`crypto` hashes every password and mints every session secret. `web` is the
server. Every one of those loads lives in a module under `src/` — the install
libdir, once installed — so the whole exposure is one directory tree, and it is
a tree gdash can look at before doing anything else.

**Built.** `src/gdash_shadow.bas`, called first by all four entry points: the
CLI, the server, the scheduler, and the refresh child. The child checks for
itself because it is a later process holding the source credentials.

- The guarded list is hardcoded and then **checked against the source**:
  `tests/test_shadow.bas` reads every module under `src/`, collects every
  `load <name>` with no `from`, and fails if the list and the source disagree
  in either direction. A library added to gdash without being added to the
  guard is a test failure rather than a silent hole.
- `tests/run_shadow.sh` pins the **premise** before the guard — it plants a
  `chart.bas` in a copy of `src/` and demonstrates what the platform does with
  it. **This paid for itself within a day:** when the rule narrowed, the deep
  case went red and named itself, rather than leaving the guard quietly
  defending against nothing. It now pins the new rule in both directions —
  beside wins, below does not, and gdash keeps running over a file below.
- 34 in-process assertions, 17 across processes. Eight mutations, all caught
  legibly: dropping a name, removing the recursion, matching folders, matching
  substrings, dropping the path from the message, and unwiring each entry
  point. The server mutation is why every invocation in that runner has a
  `timeout` — a guard that reports without exiting leaves the server serving,
  and the suite hung on exactly that.

**What the guard cannot do, stated.** Loads resolve before the program body
runs, so no gBASIC program can inspect its module directory before a shadow is
loaded. What makes the guard sufficient anyway is that a library body
**defines** rather than **runs** — a top-level `print` inside a library
produced nothing at load — so a shadow is inert until something calls it, and
gdash refuses before calling anything. Both measured, not assumed.

**Scope, stated.** Only an exact `<name>.bas` is checked, because only an exact
filename can win: the platform's fallback scan of arbitrary `.bas` files for a
matching `library` block runs **only** when nothing matched by name anywhere,
and the stdlib always matches by name for a gdash that can run at all.

Reported upstream in `gdash12_platform_report_nlq.md` §2, **answered and
shipped** — see `nlq_gdash12_reply.md` §3.

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
- `gdash_shadow` — the shadowing refusal (S0-2), enforced by all four entry
  points, with the platform premise pinned alongside the guard.
- `gdash_paths.module_dir` — where gdash's own modules live, which is also the
  directory every bare-name `load` resolves against. It shares the `GDASH_SRC`
  override with the refresh child (G8-2) rather than deciding the same thing
  twice.

### A note on `discovery`

gdash does not load it and will not, so it is not in the namespace audit. Worth
recording that if it ever does, two names collide: `scan` (with `gdash_sql`)
and `explain` (with `gdash_auth_ldap`). Harmless under the platform's
own-library-first resolution since `d08409f`, but it would need accepting with
a reason rather than discovering by surprise.

- **The model wiring**, behind a seam (`gdash_ask`):

      wire = { ctx, complete: fn(ctx, system, user) -> { ok, text, reason } }

  Live is one wrapper over stdlib `llm`; `tests/model_double.bas` is the other.
  Every exit is a value with a `stage` — data, ground, model, sql, run,
  answered — so a person is told where it stopped, and a test can assert where
  rather than only that.

- **Every attach in gdash is read-only** (`file:...?mode=ro`). Nothing is lost:
  dataset files are written by `materialize` through their own connection and
  made visible by a rename. It matters most for SQL a model wrote —
  `nlq.check_sql` is the gate that stops a generated `delete`, and this is what
  makes a gap in that gate harmless. Asserted by going around the check.

- **`gdash ask`**, and `--promote`. A question prints the query, the unit
  notes, the `data as of` and the rows; promotion writes it into the draft
  record as a visual, on the first tab, validated before it is written.

- **Requalification**, which is where the two tiers disagree: the NLQ catalog
  names a table `orders.orders`, a visual query names it `orders`. A promoted
  query is rewritten across that line.

- **Money, one step later than step 0.** An aggregate of minor units is still
  minor units, so a promoted `sum(amount) as total` would render 215100 for
  $2,151.00 — the same failure, in the chart instead of the answer. Promotion
  sets `format: "currency"` for an aggregate directly over a money column, and
  for nothing else: `count(amount)` is not money, and only the aggregate's name
  separates it from `sum(amount)`.

- **`provider: "offline"`** — the platform's own fixture transport, so an
  operator can verify an install end to end with no key, no network and nothing
  spent. It is also what makes the end-to-end assertions hermetic.

- **The browser panel.** `GET/POST /d/{name}/ask` and
  `POST /d/{name}/ask/promote`, editors of the draft. The suggested visual is
  RENDERED — ordinary query, ordinary attach set, ordinary renderer — so the
  preview is not a mock of what promotion would produce, it is what promotion
  would produce. Measured end to end: the chart's axis reads $1,000.00 to
  $4,000.00 rather than 100000 to 400000. The draft rides the session between
  asking and promoting, so no SQL comes back from the browser and no second
  model call is spent.

- **The corpus**, `tests/run_nlq_corpus.sh`, and the numbers it gives:

      answerable questions grounded:  15/15
      unanswerable questions refused:  5/5

  Hermetic, and in the suite, because `nlq.plan` does no I/O: how often gdash's
  own catalog settles a reasonable question is measurable with no model. The
  answer tier — whole pipeline, real model — is gated on `GDASH_NLQ_TEST=1`
  and will never be in the suite: it costs money, needs the network, and gives
  a distribution rather than a pass.

  **It found a real gap in the first run.** `nlq.plan` refuses on AMBIGUITY and
  does not refuse a question the catalog has nothing to do with — it returns
  `ok` with a prompt naming no tables. All five unanswerable questions planned
  `ok`, and every one would have been sent to a model, paid for, and then
  refused by `check_sql` for naming a table nobody offered.
  `nlq.check_answerable` is the library's own rule for this and is now wired in
  before the model call.

  It also found a gap in itself: the first version called `nlq.plan` directly
  and so scored 20/20 with gdash's own check mutated away. It now runs through
  `gdash_ask.ask` with a model double, which is the thing that can regress.

## Still to build

- The recall numbers against a **real** model. The runner is there and gated;
  what it needs is a key and somebody's decision to spend it.

---

## DONE

Delivered. `docs/gdash12_findings.md` has the detail.

- **`gdash_shadow`** — gdash refuses to start when a stray `.bas` in its own
  module directory would replace a library it loads by name. All four entry
  points; the guarded list is checked against the source, so a library added
  without being guarded is a test failure rather than a silent hole.
- **`gdash_nlq`** — the catalog, the scaled columns, and the **unit guard**:
  the part only gdash can write, because only gdash knows the scale.
- **`gdash_ask`** — the pipeline behind a seam, `gdash ask` and `--promote`,
  the browser panel, requalification, and the currency format on a promoted
  money channel.
- **Every attach read-only**, which makes a gap in `check_sql` harmless rather
  than destructive.
- **`gdash_store.describe_datasets` / `sample_column` / `select_across`** — the
  cross-dataset read, which closes **G2-3** by construction.
- **The corpus**: 15/15 answerable grounded, 5/5 unanswerable refused,
  hermetic, in the suite.

Suite: 35 suites, 0 failed — 1 072 in-process, 244 end-to-end, 21 multi-worker,
17 shadow, 11 ceiling, 10 drain, 9 concurrency. Opt-in ODBC 12 and FHS 22
re-run green. Postgres and LDAP untouched. Nothing pushed.

### Deliberately not built

- **An answer cache.** `nlq` supplies `plan.key` for one. Promotion stores the
  SQL, not the question, so a dashboard never re-asks; the only caller who
  would benefit is a person re-asking the same words in the drafting UI.
- **A chat history, or a follow-up question.** Each question is grounded on its
  own. "And by month?" would need conversation state, which is a different
  design and a different set of failures.
- **Choosing between ambiguous candidates in the UI.** The refusal carries them
  and both the CLI and the page print them; neither offers a click to pick one.
- **A model-side retry.** If the model writes SQL that does not compile, the
  draft says so and a person asks again. Retrying automatically would spend
  money on a guess about why it failed.
- **Recall against a real model.** The runner is built and gated on
  `GDASH_NLQ_TEST=1`; it needs a key and a decision to spend it.

### Owed to the maintainer

Carried forward from earlier phases and still unmade, since a design ruling is
not this phase's to make silently:

- §5's SSE sentence is wrong in mechanism and right in principle (GDASH-11).
- Whether publish should carry the draft's data across (G11-11).
- §8's `memberOf` sentence, `password_hash` naming, local-provider-first.
- §4 money headroom and the render path; §2 content-hash.

New, and the largest of them: **the design document says nothing about asking
questions in English.** This phase built it against `nlq_contribution.md` §6
and the GDASH-12 brief, both of which are this session's arguments rather than
the maintainer's rulings. Three things in particular are decisions rather than
implementations, and each is defensible another way:

1. **A question edits the draft, so the draft's edit groups govern it.** The
   alternative is a separate permission — asking costs money, and "may edit
   this dashboard" is not obviously the same right as "may spend tokens".
2. **The draft rides the session between asking and promoting.** The
   alternatives were accepting SQL back from the browser, or paying for a
   second model call.
3. **Promotion places the visual on the first tab.** A visual in `visuals` that
   no tab names renders nowhere, so doing nothing would be a promotion that
   appeared to work — but the first tab is a guess.

### Cross-repo, open

- `gdash8_platform_report_tls.md` — TLS pass-through is ignored by `serve`;
  gdash refuses to start rather than serve cleartext.
- `gdash12_platform_report_nlq.md` — three findings now: no channel for a
  column's units (§1), the shadowing rule (§2, corrected), and `plan` returning
  `ok` for an unanswerable question (§3). Plus the grounding-tier numbers.
