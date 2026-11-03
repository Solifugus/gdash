# gdash on G-SQL: the migration plan

**Status:** proposal, 2026-11-02. No phase is open for it. The maintainer
ruled on D1, D3, D4 and D5 the same day and left D2 to this plan's judgement
(§3). D4a is still open. It becomes a brief (proposed number GDASH-20) when
the phase opens. It was written
against gbasic `4b219e9` and the installed interpreter `/usr/local/bin/gbasic`,
which reports **0.10.0**.

## 1. What changes and what does not

G-SQL replaces SQLite as the staging store. The source side does not change:
dataset queries still run on Postgres or ODBC in the refresh child. This is
the backend swap that design §3 put behind `gdash_store` so that it would be
"one module's rewrite". The rewrite is mostly in that module. Four other modules
change because they relied on SQLite-specific behaviour: refresh, render/format,
the record validator and ask.

**No data migration is needed.** gdash has no deployments, and design §6 makes
`/var/cache` disposable. Old `.db` files are deleted and a refresh rebuilds the
data. The record SQL to convert is the reference dashboards, the fixtures and
the tests. `docs/gdash_sql_corpus.json` lists all of it: 29 statements.

## 2. What was measured today (scratch probes, installed 0.10.0)

| question | answer | consequence |
|---|---|---|
| Atomic swap under a live reader | A reader in `begin("read")` kept seeing the old `orders` after another connection ran `drop table orders; alter table orders__staging rename to orders` in one transaction. Its next snapshot saw the new table. | Design §3's stale-but-coherent model holds without a file rename. **Holds.** |
| Engine-level read-only | `delete` inside `begin("read")` was refused with `READ_ONLY`. | Replaces the `mode=ro` attach as the second line of defence behind `nlq.check_sql`. **Holds.** |
| Per-request cost | connect, `begin("read")`, a `sum`, commit, close: **0.14 ms** each over 1 000 requests with the owner warm. A cold owner start plus one query took 20–30 ms. | Workers can keep opening a connection per request. Set the owner's linger to seconds, not 0. |
| Integers above 2^53 | They round-trip exactly. `sum` over them is exact. | The `__text` casts and the `exact` argument go away. |
| Money precision | `money(USD)` stores **6** decimals and `money(JPY)` stores 4 (the minor unit plus four guard digits). More decimals than that are refused. Anything up to that limit is **accepted**: `'1250.7512'` goes into a column gdash declared at scale 2. | G-SQL does not enforce gdash's per-column scale. gdash keeps the excess-decimals check (design §4), but not the conversion. |
| Money as text | `string(m)` and G-SQL's `cast(m as text)` round to the currency's minor unit, half-even: 1250.7512 comes back as `"1250.75"`. `money.text(m)` renders at the storage scale and round-trips; `money.text(m, n)` renders at `n` places, half-even. | The format layer renders with `money.text(m, scale)`. A scale-4 `rate` column needs nothing new. Finding S1 covers the SQL cast. |
| Rounding mode | Half-even throughout: `1250.745` and `1250.735` both become `1250.74`, `1250.755` becomes `1250.76`, and JPY `100.5` and `101.5` become `100` and `102`. `-0.005` at 2 places renders as `"-0.00"`. | Display rounding is unbiased already. Finding S2 covers the negative zero. |
| Implicit casts | `amount > 1` is refused (`EXPRESSION`: money compared with a number). `d >= '2026-10-01'` against a `date` column is refused too. gBASIC itself refuses both (`money comparison requires money values`, `date/time comparison requires date/time values`), but answers `1 = "1"` with a plain `false`, where G-SQL refuses the same comparison. | Params can no longer be bound as untyped text against typed columns (D3). Findings S3 and S4 cover the rule. |
| Text into an `integer` column | **Refused on 0.10.0.** The gbasic CHANGELOG says this is accepted "after 0.10.0" (`4b219e9`). | The phase needs a pinned platform version, or gdash converts the values itself. Step 0. |
| Dialect odds and ends | `drop table if exists`, quoted identifiers, multi-row `VALUES` and `order by 1` all work. | The visual SQL in the corpus probably runs unchanged. Step 0 confirms it statement by statement. |
| Catalog / describe | There is no `pragma table_info` equivalent, and nothing like `sqlite.columns` that describes a query's result without running it. | gdash's own meta table stays the authority for columns. The `sqlite.columns` ask becomes a G-SQL ask (P3). |

## 3. Decisions for the maintainer

### D1. How big is a database? **Ruled: one database per (dashboard, stage)**

**Where tenants go:** in a directory, not a prefix. A tenant is already a root
with its own cache directory (`gdash_saas_design.md` §1), so its databases are
`<tenant root>/cache/<dashboard>/{draft,published}.gsql`. A tenant-name prefix
on databases in a shared directory is the arrangement that design rejects by
name ("Why not a prefix, a shared directory, or a tenant column"): there, the
wall is a string every path has to get right; with directories, it is the
filesystem. Single-tenant installs keep the same layout under their one root.

The gbasic storage design (§5.1.1a) recommends **one database per deployment
or per tenant**. The 2026-10-23 relay accepted that for tenants. This plan
recommends something finer: `cache/<dashboard>/published.gsql` and
`cache/<dashboard>/draft.gsql`.

- **Isolation by construction.** In a tenant-wide database, every dashboard's
  SQL can name every other dashboard's tables. Dashboards have different view
  groups (§8), so gdash would have to parse and rewrite author SQL and model SQL
  to prevent cross-reads, and one miss would be a disclosure. The SaaS design
  rejected exactly that argument ("the wall between tenants is the filesystem,
  not the code", `gdash_saas_design.md` §1). The same argument applies here one
  level down.
- **Author SQL keeps its names.** `from orders` resolves to this dashboard's
  `orders`. Draft and published need the same table names, so they have to be
  two databases anyway, unless gdash rewrites names.
- **It keeps every gain the storage design promised:** no attach cap, since a
  dashboard's datasets share one database; no attach-every-sibling; one owner
  per open dashboard rather than one per dataset.
- **The cost:** one owner process for each dashboard being viewed. Owners
  start on demand in about 20 ms and stop after their linger. The 10²–10³
  figure in the volumes answer counts dataset files; owners count only
  dashboards currently open.

A tenant is still a root (`gdash_saas_design.md`), and its databases live
under its cache directory. Per-tenant isolation therefore holds as before.

### D2. Sequencing with GDASH-19. **Decided (left to this plan): migrate first**

GDASH-19 stays at step 0 until this phase is done. After that, its brief is
re-read against G-SQL, and two of its rulings are revisited: `date` as text,
and bounds in a table beside `_gdash_meta`.

GDASH-19 has finished step 0, and nothing of it is implemented yet. Both of its
rulings are written against SQLite:

- the bounds table beside `_gdash_meta`;
- `date` is "validated, stored as TEXT", which was chosen partly because
  SQLite has no date type.

Under G-SQL a native `date` column gives that validation from the engine. It
also turns every comparison against text into a refusal, which is D3.
Implementing GDASH-19 first means writing date and bounds code twice.

### D3. Param types. **Ruled: params declare a type, and gdash binds a typed value**

SQLite's type affinity hid this problem. G-SQL refuses `where qty > :min` when
`:min` arrives as the text `"5"`. Every param value travels from the page as
text, so the change touches the record format. There are three options:

- **(a) Authors cast in SQL:** `cast(:min as integer)`. No format change, but
  a forgotten cast fails at render time.
- **(b) Recommended: params declare `type`** (`string`, the default, plus
  `integer`, `number`, `date`, `money`). gdash converts the value at the server
  and binds the typed value. A value that does not convert is refused, not
  coerced, as with money. A type-checked param is also the shape GDASH-19's
  date controls need.
- **(c) Infer the type from the default value.** This is silent, and it breaks
  when the default is an empty string.

`user_*` params stay strings. Today's reference params are all strings that
match text columns, so (b) costs nothing until a record uses it.

### D4. Money's stored form. **Ruled: `money(<currency>)` columns**

A declared money column becomes `money(<currency>)`. Validation refuses a
`scale` above the currency's storage scale (USD 6, JPY 4). Two invariants
change wording as a result, in CLAUDE.md and design §4: "INTEGER minor units"
and "scale in `_gdash_meta`".

### D4a. What a source value with more decimals than the declared scale means. **Open**

The question is what happens to `1250.7512` arriving for a column declared at
scale 2.

- **(i) Refuse it, as design §4 says today.** The refresh fails and the old
  data stays. gdash keeps its scale check.
- **(ii) Round it half-even to the declared scale at import.** This is the
  rule gBASIC applies to a computed number. It is unbiased across many
  values, but it still changes the stored figure. Every sum then adds up
  rounded parts, so a total can differ by up to half a cent per row from the
  exact total. This is the silent rounding that §4 was written to prevent.
- **(iii) Recommended: store it exactly, and round only when displaying.**
  §4's refusal rule was a SQLite-era necessity: minor units at scale 2 had
  nowhere to put a third digit. `money(USD)` has room for six. Under this
  option:
  - the source value is stored as given;
  - `sum` is exact over the true values;
  - the declared `scale` becomes the **display** scale, rendered half-even by
    `money.text(m, scale)`;
  - nothing is rounded except what a person reads.

  The one refusal left is gBASIC's own: text with more decimals than the
  currency can store (a seventh place for USD) is refused by the money parser.
  gdash's scale check, the last piece of `to_minor`, goes away.

  The cost: the displayed rows of a table may not add up exactly to its
  displayed total, because each row is rounded separately. Any report that
  rounds shows this. With (ii), the displayed total is the sum of rounded
  values, which is worse, because it is the stored figure that is wrong.

**Headroom does not change in practice.** The money type already caps
rendering at USD 9.2 trillion (`gdash_record_format.md`, currency range). What
changes is where the cap is hit. Today the stored value is fine and rendering
refuses it. After the migration, the refresh refuses a value over the cap. A
`sum` that overflows raises warning 2112, which gdash runs under `on warning
stop` and reports as the visual's error.

### D5. Undeclared columns. **Ruled**

Today inference maps integer-looking values to INTEGER, numeric ones to REAL
and everything else to TEXT. Under G-SQL a column's type **is a gBASIC kind**,
not an SQL type that resembles one: `integer`, `number` and `string`. The
column's kind decides how a compatible value stored into it is converted.
gdash keeps inferring the kind from the fetched rows. The source rows arrive as
text, so step 0 checks the conversion for each kind gdash infers. If it is
missing for one (numeric text into a `number` column is the one not probed),
the fix belongs to gBASIC, through finding S3's rule. gdash does not work
around it.

## 4. The target, assuming the recommendations

- **Layout:** the resolver adds `dataset_db(dashboard, stage)`. A database
  holds one table per dataset and one `_gdash_meta (dataset, column_name, kind,
  currency, scale)` table. Validation reserves dataset names that start with
  `_gdash` or end in `__staging`.
- **Refresh:**
  1. The child connects to the database, runs `drop table if exists
     <ds>__staging`, creates the staging table and inserts rows in transactions
     of about 1 000 rows. Each money cell is scale-checked, then bound as text,
     and G-SQL converts it.
  2. The child prints its row count and content hash as today.
  3. If the hash moved, the parent runs **one transaction**: drop `<ds>`,
     rename the staging table to `<ds>`, and replace that dataset's
     `_gdash_meta` rows. Then it bumps the version file.
  4. If the hash did not move, or the child failed, the parent drops the
     staging table. The live table is never touched. This is stale-but-coherent
     with the transaction doing the rename's job.
- **Reads:** every visual query, `describe_datasets`, `sample_column` and
  `select_across` runs inside `begin("read")`. Money comes back as money and
  integers come back exact. `money_columns` reads `_gdash_meta` from the same
  database, so the schema-qualification trap (G2-3) and the collision rule
  (G13-2) are left with nothing to protect against.
- **Ask:** catalog tables are plain `<dataset>`, not `<ds>.<ds>`. The dialect
  string becomes G-SQL, with notes covering no implicit casts and money
  literals written as `cast('1000' as money(USD))`. The minor-units warning and
  the unit guard's cents-vs-dollars clause are deleted, because that mistake is
  now a loud `EXPRESSION` refusal instead of a silent wrong answer.
- **Owners:** linger comes from `server.json` (proposed default 30 s). The
  suite uses `linger: 0`. The scratch-clean assertion also checks that no owner
  process is left serving the temporary root, and checks it by path, so the
  suite never touches anyone else's processes.

### What gets deleted

`to_minor`'s conversion half; `_ro_uri`, `_attach_one`, `_connect_across`,
`attach_limit` and the record validator's 11-dataset rule; the `__text`
casts and the `exact` argument; schema-qualified meta reads; `swap`'s file
rename for datasets (the version file keeps its rename); `load sqlite`.
`gdash_nlq.bas` currently reaches into the private
`gdash_store._connect_across`, and that dependency goes too.

## 5. The phase, in order

0. **Step 0. If any check fails, stop.**
   1. Pin the platform. Build gbasic at or after `4b219e9` and point
      `GDASH_GBASIC` at it, or decide that gdash converts integers itself.
   2. Run all 29 corpus statements against G-SQL and record each outcome.
   3. Confirm `nlq.catalog` accepts tables with no schema.
   4. Confirm the format layer renders through `money.text(m, scale)` (P2 is
      withdrawn).
   5. Check the owner under a `--root` temp dir: where its socket and spill
      files go, and that scratch-clean holds.
   6. Check the owner under the systemd unit (`ProtectSystem=strict`,
      `ReadWritePaths`).
   7. Measure a refresh at 10⁴ and 10⁶ rows, which also gives the refresh
      duration number the volumes answer owed.
1. **Tests first.** Pin each of these:
   - swap under a live reader;
   - a failed refresh leaves the old table untouched;
   - a write inside a read query is refused;
   - excess decimals at the declared scale are refused;
   - an integer above 2^53 round-trips;
   - a dashboard with 20 datasets works (the cap is gone);
   - one dashboard's SQL cannot name another dashboard's table;
   - a typed param is bound, and a malformed one is refused (D3).
2. Rewrite `gdash_store` against G-SQL, keeping its verbs where they still
   mean something.
3. Rewrite refresh and the refresh child: the staging table, batched inserts,
   and the parent's swap transaction.
4. Render and format: native money and native integers.
5. Record validation: remove the attach cap, reserve the names, check scale
   against the currency, and add param types.
6. Ask: the catalog, the dialect notes, and the unit-guard removals.
7. Convert the reference and fixture SQL. Update `gen_sql_corpus.py`'s store
   entries and regenerate the corpus.
8. Housekeeping: add `gsql` to the shadow guard's list, and update the
   operations guide, the record format and the README.
9. Findings, the DONE note, and the design edits below.

**Deliberately not in this phase:** bounded-memory refresh. G5 is ready on
G-SQL's side, but gdash's source seam returns every row at once, so this is a
separate phase on the fetch side. Also out: publish carrying draft data across
(G11-11, still unruled); first-class dataset sharing; and any multi-tenancy
work beyond keeping the layout tenant-rooted.

## 6. Design edits owed

- **§3:** "local SQLite files", the "two dialects" paragraph, and the whole
  *Staging store: SQLite, and why not Postgres* section. The reasoning
  survives: no service to run, and the suite stays hermetic. The ruling changes.
- **§3 Refresh:** `<dataset>__staging.db` and the rename become the staging
  table and the swap transaction.
- **§4:** the stored form (D4), the `decimal_sum` escape hatch, and "SUM …
  exact over 64-bit integers" (now: exact as money, up to the currency's
  range).
- **§6:** cache layout `<name>/{published,draft}.gsql`.
- **§9:** `sqlite.columns` becomes a G-SQL ask.
- **CLAUDE.md invariants:** the swap sentence and the money sentence.
- **`gdash_saas_design.md`,** where it names dataset files.

## 7. Platform findings, for gbasic through its own process

- **P1.** Storing text into an `integer` column is refused on the installed
  0.10.0 and accepted at HEAD. This is not a defect. It is a version gdash must
  pin.
- **P2.** *Withdrawn.* `money.text(m, n)` already renders at a stated number
  of places, half-even. What remains is S1.
- **S1. A text conversion of money in SQL should be lossless.** `cast(m as
  text)` rounds to the minor unit, so `1250.7512` becomes `"1250.75"` and does
  not read back as the same value. A cast is a data path: its output gets
  stored, compared and sent on. It should match `money.text(m)`, which
  round-trips, and leave rounding to an explicit width. The same question
  applies to `string(m)` in gBASIC. It reads like a display function, but
  anything that serializes through it loses the guard digits.
- **S2. Negative zero.** `money.text({USD}"-0.005", 2)` is `"-0.00"`. A value
  that rounds to zero should render as `"0.00"`. Otherwise a ledger shows a
  minus sign on nothing.
- **S3. A rule for comparisons that has limits.** Comparisons with no
  conversion at all are too strict for real queries: every date filter needs a
  cast. Converting anything to anything is too loose. The proposed middle is
  the rule storing already uses, the kind decides:
  - When one side of a comparison has a kind (a column, or a typed value) and
    the other side is a **text literal or parameter**, the text is read as that
    kind by that kind's own parser, the same one storing into the column uses.
    If it does not read as that kind, the comparison is refused.
  - Under that rule:
    - `day >= '2026-10-01'` against a `date` compares dates;
    - `amount > 1000` against `money(USD)` compares USD 1000, as a number
      stored into that column takes the column's currency;
    - `id = '25'` against `integer` compares 25, with the same whole-number
      rule as storing.
  - Still refused, because the kinds are not comparable:
    - date with number;
    - money with date;
    - boolean with anything but boolean;
    - `money(USD)` with `money(EUR)`;
    - two sides that each already have a kind and differ, where neither is
      text, because there is no side to decide.

  If G-SQL adopts this, D3's typed params are still worth having, because a
  bad value is then refused before any query runs. They just stop being what
  makes a date filter work at all.
- **S4. gBASIC and G-SQL disagree on `1 = "1"`.** gBASIC answers `false` and
  G-SQL refuses the comparison. The overview says operators in a query are
  gBASIC's own, so one of them is wrong. The silent `false` is the trap: a
  program comparing an id read from a form with a stored number never matches,
  and never says why. Under S3 both would read the text as a number, or refuse
  it.
- **P3.** No catalog, and no describe-without-execute. This replaces the
  `sqlite.columns` ask.
- **P4, an optional ask, needed only if D4a is ruled (i):** `money(USD, 2)`,
  a declared scale the engine enforces, so that gdash's scale check goes away.
  Under (iii) the check is gone anyway, and so is the last of `to_minor`.
