# GDASH-20 — findings

The staging store moved from SQLite to G-SQL. Step 0 is in `gdash20_brief.md`
and the rulings are in `gsql_migration_plan.md`. These findings are what the
build itself found. Each has a status: **fixed**, **asked** (of the platform),
**ruling owed**, or **noted**.

## G20-1 — the suite was red before the phase started — *fixed* (f8fd8b5)

gbasic `4f3eb1e` made `=` and `!=` propagate `unknown`, and an `if` on
`unknown` raises. gdash compared absent record fields as if that answered
`false`, so 14 of 37 suites raised on the current build. Every site now keeps
its old meaning through `default(...)`. The identity's `admin` flag was the
one that mattered: it was built as `admin = true`, and was `unknown` for a
user record with no `admin` key. This was fixed first, as its own commit,
with no change in behaviour.

## G20-2 — the owner's socket under `PrivateTmp` — *fixed by the platform* (A1, gbasic `d2e310e`), measured both ways

This is S0-6, the one step-0 check that failed. It was predicted by analysis
in step 0 and has now been measured. `run_systemd.sh` gained a probe that
reproduces it: a viewer opens a published dashboard, so a server worker
starts that database's owner, and the scheduler unit refreshes the same
database 1.5 s later.

**Measured (build `db72b76`): a stall, not a failure.** The scheduler pass
took **28.5 s**, ending just as the server owner's 30 s linger (begun 1.5 s
before) ran out. The uncontended pass was not timed. Its client
cannot see the server's owner, loses the lock race and retries, and gets
through only when the server's owner has lingered out (30 s). Step 0 predicted
an outright failure. The prediction was wrong in shape: the client's bounded
retry outlasts a 30 s linger. The direction was right.

**The real-world consequence is worse than the probe.** Every request renews
the linger, so on a dashboard people are actively using the server's owner
never stops. The refresh then stalls until the client's retries run out and
the pass fails. The probe is green while the limit holds, and goes red when A1
lands, saying so.

**Fixed by gbasic `d2e310e`**, which puts the socket inside the database
directory. The probe is now a plain assertion. Under real systemd, against a
build of `d2e310e` made from a clean `git archive` in the scratchpad (the
installed interpreter was still `db72b76`), the same overlapping pass took
**361 ms**, with nothing failed. That is the first real-systemd measurement of
A1, and the systemd suite is 40/40. The hermetic suite is 37/37 on that build.
gdash's connect code did not change. The one new constraint is that a
database directory other users can write is refused, and `gdash_operations.md`
§4 says so.

## G20-3 — trailing zeros fail a money column again — *fixed by the platform* (A6, gbasic `8633507`); the stopgap is gone

gBASIC's money reader counts characters after the point, not significant
digits. So `1100.00000000`, which is how a `numeric(19,8)` source renders an
exact whole amount, is refused. The old `to_minor` had a rule for this (G9-6),
and deleting `to_minor` deleted the rule with it.

The unit suites could not have caught it, because fixtures do not pad.
Postgres does. The live Postgres runner caught it: a `numeric(20,8)` column
failed its refresh.

For a while `gdash_store` stripped trailing zeros from money text before
binding it, as a stopgap. gbasic `8633507` made the money reader count
significant digits, and the stopgap was deleted, so nothing of `to_minor`
remains.

Measured on a clean build of `8633507`:

- `test_store` is green, and pins the padded values through the store. The
  same suite on `db72b76` fails, naming the refusal.
- Live Postgres (`numeric(20,8)`) 10/10, ODBC 12/12, hermetic 37/37.

A non-zero digit past the currency's storage scale is still refused.

## G20-4 — dollars added to yen is refused by the engine — *noted*, a correctness gain

`select usd_value + jpy_value` used to add two integers of minor units without
a word. G-SQL refuses it, because the operands are money in two currencies.
The render suite's ambiguous-scale case had been written that way, and was
rewritten over a single currency (`usd_value * 1`). A new assertion pins the
refusal.

## G20-5 — a money column's currency is now load-bearing — *noted*

A money column declared without `currency` is USD, which was true before as
well. What changed: with minor units, the declared currency only labelled the
rendering. Now the stored value carries its currency, and a visual that
states a different one is refused rather than relabelled. The render suite's
fixture declared a yen column with no currency and formatted it as JPY. That
was silently wrong before, and it is refused now. The fixture now declares
JPY. The reference treasury record already did.

## G20-6 — G-SQL dialect gaps an author meets first — *fixed by the platform* (A5, gbasic `0424a49`)

These are refused by G-SQL, and SQLite and PostgreSQL both accept them:

- no `substr`/`substring` (the function list is ten names long);
- `GROUP BY` an output alias;
- `GROUP BY` a position.

gdash's numeric-x chart tests used `cast(substr(month, 6, 2) as integer) ...
group by period`. Two suites were rewritten with a `CASE` in a derived table,
which suits a fixture and not real data. Nothing in the reference records used
any of these, so the corpus ran unchanged (S0-2). Authors' own SQL will hit
them, and so will SQL from a model.

After the maintainer's ruling on spellings, gbasic `0424a49` added
`substring(x, start [, length])`, `extract(part FROM value)`, and `GROUP BY`
by position or alias. Both rewritten tests went back to the natural SQL. On
the old builds `GROUP BY 1` grouped by the constant 1 and blamed the select
list; that was fixed in the same change.

## G20-7 — `WITH RECURSIVE` past a million rounds is refused — *noted*

The drain runner's deliberately slow query counted to forty million
recursively. G-SQL refuses that by design (`max_recursion`, a million by
default), so the "slow" render failed in 1.6 s and the drain could not land
mid-flight. It is now a filtered cross join of 1600² rows, about 4 s.

## G20-8 — the GDASH-12 failure answers correctly now — *noted*

"How many orders were over 1000 dollars?" produces `amount > 1000`. Against
minor units that returned 3, a hundredfold wrong. Against money it returns 2,
the true answer. Because the store no longer holds minor units, three things
go:

- the literal-restating guard (`unit_notes`);
- the minor-unit prompt notes;
- the cents-versus-dollars clauses.

The model is now told each money column's currency. `units_told` keeps its
shape and means "the currency notes reached the model".

## G20-9 — the scale-conflict refusal (G13-2) now guards only places shown — *ruled 2026-11-07: fall back, do not refuse*

With minor units, two datasets declaring `amount` at different scales made a
wrong number possible, so the renderer refused. With exact money, the amount
is right whichever scale is chosen, and only the number of places shown is
ambiguous.

**Ruled by the maintainer (2026-11-07):** an unresolved scale falls back to
the currency's own minor places (USD two, JPY none), and nothing is refused.

- `gdash_render.places_for` decides the places per value, from the value's
  own currency.
- The promotion caveat, which existed only to explain the refusal, is gone.
- A promoted draft now states its value's currency, not the first one in
  reach. Before, a yen aggregate on a dashboard whose first money column was
  dollars would have been stamped USD and refused at render.
- Building the change also found that the cut removing the caveat had taken
  `_dialect` and `_carries_money` with it. Every question then failed with
  "could not be planned", and that message hid the reason, which was an
  undefined function. The refusal now carries the library's own reason.

## G20-10 — a NULL money cell is stored as NULL — *noted*, behaviour change

`to_minor(unknown)` refused the cell as "not a decimal number", so a source
NULL in a money column failed the whole refresh. A NULL is now stored as
NULL, as it is in every other column kind. An empty string is still refused,
because it is not an amount.

## G20-11 — `type()` of a date is `"datetime"` — *noted*, documented platform behaviour

A typed `date` param binds a date value whose `type()` is `"datetime"`. That
is in gBASIC's reference: a date is the date-time kind with no time part. The
test had expected `"date"`, and the test was wrong.

## G20-12 — `find` answers `nothing`, not -1 — *noted*

The trailing-zero stopgap compared `find(...) < 0`, which raises on `nothing`.
Inside `materialize`'s `on error goto next` the raise did not surface. It
dropped the value from the insert, so the error that appeared was "no value
was given for the parameter $1". `test_store` caught it.

## G20-13 — method, stated plainly — *noted*

- **Tests did not come first for the store.** The rewritten `gdash_store`
  went in before `test_store` was rewritten for it. That suite then pinned it
  (72 assertions on the first run, one failure), but the house order is tests
  first, and it was not followed there.
- **The work lands in one code commit, not several focused ones.** The store,
  the renderer, typed params and the question path touch the same files
  (`gdash_record`, `gdash_app`, `run_e2e.sh`). Splitting them would have meant
  staging by hunk, which this environment cannot do interactively. The commit
  message lists the parts.

## G20-15 — a concurrent-render request that is never answered, intermittently — *open*

`run_workers.sh` "eight concurrent renders all succeed" failed twice in about
a dozen runs. Four of the eight `curl`s got no response within 20 s (`000`),
and the server log showed no error. It happened on `132bf50` and on
`0424a49`, so it is not caused by the change being tested. It did not
reproduce in six further runs, three with `GDASH_GSQL_LINGER=0` and three
with 5. Whether it existed on SQLite is unknown: the suite's runs before the
migration did not show it, but they were too few to say.

**A suspected mechanism, then measured by gbasic and largely ruled out
(2026-11-07).** An owner stopping at its last close removes its socket first
and releases the store's lock last, and a connect arriving in between starts a
second owner that waits for the lock. gbasic built that window on purpose by
slowing the stopping owner's syncs. The waiting client was served as soon as
the old owner finished: at 6.0 s for a 6 s stop. The client's 10 s retry
steps cost extra only when a stop takes longer than 10 s (a 72 s stop was
served at 80 s). On local disk with small data a stop takes milliseconds:
16 workers × 100 connect/close rounds at linger 0 never exceeded 0.6 s. So
that window explains a 20 s stall only if something makes an owner's stop
take over 10 s. gbasic keeps the experiment as a regression tier
(`run_gsql_owner.sh` "window").

**Cause: unknown.** The workers suite stays at linger 0, so it keeps exposing
whatever this is. The next step is per-call connect timing in the store under
a trace switch, run in a loop until a failure is caught. If a slow call
appears, capture the owner's own stop time as well: the owner's pid from the
connection, and when it exits. Until then, a red workers run is worth one
re-run before it is believed.

## G20-14 — the bulk insert (A3) is adopted, and the rest of a refresh is gdash's own cost — *noted*

gbasic `f02455a` added `db.insert(table, rows)`. `materialize` now hands it a
thousand records a call, one transaction each. A refused row is named by
`error.details.index`, which replaced both the hand-built multi-row `INSERT`
and the row-by-row retry used to find the bad row.

Measured on that build, with the time to build the source rows subtracted:

| rows | 10 rows a statement | `db.insert` |
|---|---|---|
| 10⁵ | 3.6 s | 2.8 s |
| 10⁶ | 38.9 s | 29.5 s |

About 25% faster. gbasic measured the insert itself at 5.2 s per million
rows, so most of what remains is gdash building one record per row in
interpreted gBASIC: about 6 µs a cell. At the volumes the answer to the G-SQL
volumes ask expects (10²–10⁴ rows typical, 10⁶ the largest), that is seconds
at most, and not worth restructuring for now.

## The platform moved under the phase — *noted*

Step 0 ran on `0.10.0+cac666c`. During the build the installed interpreter
became `0.10.0+db72b76`, installed by the gbasic session. Every result after
that point, including the suites reported below, is on `db72b76`. The suite's
platform stamp did not fire, because no run straddled the change.

## Measured

- **Hermetic suite:** 37 of 37 green on `0.10.0+db72b76`, scratch-clean
  including G-SQL owners.
- **Opt-in runners:** ODBC 12 of 12 and live Postgres 10 of 10.
- **Refresh timings:** step 0 measured 10⁶ rows in about 48 s at one row a
  statement, with the client's memory flat. Since A3 it is about 30 s through
  `db.insert`; see G20-14.
- **systemd (real units, podman):** 39/39 on `db72b76`, with the probe
  measuring the stall, and 40/40 on `d2e310e` with it fixed (361 ms).
- **Not run:** `run_fhs.sh` and `run_ldap.sh`. Neither touches the store's
  semantics beyond what the hermetic suite covers.
