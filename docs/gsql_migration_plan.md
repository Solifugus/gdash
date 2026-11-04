# gdash on G-SQL: the migration plan

**Status:** proposal, ready to become a brief (proposed number GDASH-20) when
the phase opens. Every decision in §3 is settled. The maintainer ruled on D1,
D3, D4, D4a and D5 on 2026-11-02 and 2026-11-03, and left D2 to this plan's
judgement. The four gBASIC findings from the first draft are resolved on gbasic
master (§7). Every behaviour in §2 was re-measured on 2026-11-03 against the
installed interpreter, which reports **`0.10.0+e902acf`**.

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

## 2. What was measured (scratch probes, `0.10.0+e902acf`)

| question | answer | consequence |
|---|---|---|
| Atomic swap under a live reader | A reader in `begin("read")` kept seeing the old `orders` after another connection ran `drop table orders; alter table orders__staging rename to orders` in one transaction. Its next snapshot saw the new table. | Design §3's stale-but-coherent model holds without a file rename. |
| Engine-level read-only | `delete` inside `begin("read")` was refused with `READ_ONLY`. | Replaces the `mode=ro` attach as the second line of defence behind `nlq.check_sql`. |
| Per-request cost | Connect, `begin("read")`, a `sum`, commit, close: **0.14 ms** each over 1 000 requests with the owner warm. A cold owner start plus one query took 20–30 ms. | Workers keep opening a connection per request. The owner's linger is seconds, not 0. |
| Integers above 2^53 | They round-trip exactly, and `sum` over them is exact. | The `__text` casts and the `exact` argument go away. |
| Text into typed columns | `'25'` and `' 26'` go into `integer`, and `'1.5'` and `' 2.5'` into `number`. `'2.5'` into `integer` is refused (`TYPE`). Date text goes into `date`, and decimal text into `money(USD)`. | The refresh child binds source text as it arrives, and the column's kind converts it. gdash needs no conversion code of its own. |
| Money precision | `money(USD)` keeps **6** decimals exactly and `money(JPY)` keeps 4. A seventh USD decimal is refused by the money parser. | Values are stored as the source gives them (D4a). |
| Money as text | `money.text(m)` and `cast(m as text)` keep every digit: `1250.7512` round-trips. `money.text(m, n)` renders at `n` places, half-even. `string(m)` and `print` show the currency's places, on purpose. | The format layer renders with `money.text(m, scale)`. A scale-4 `rate` column needs nothing new. |
| Rounding | Half-even throughout: `1250.745` and `1250.735` both become `1250.74`. A value that rounds to zero shows `0.00`, with no sign. | Display rounding is already what a ledger wants. |
| Comparisons | When one side has a kind and the other is text or a parameter, the text is read as that kind. `day >= '2026-10-01'`, `amt > 1000` against `money(USD)` and `id = $1` with `["25"]` all work, and an index still seeks on them. `day > 5` is refused (`EXPRESSION`). So is text that does not parse (`day > 'not a date'`), and it names the text. | Visual SQL written against SQLite's affinity mostly keeps working. A bad param reaches the user as a refusal that names it, never as a silent non-match. |
| gBASIC's own `=` | `1 = "1"` is `false` in a program, and it now raises warning 2122, which names `number()` and `{number}`. | Form values are converted when they come in (D3), not compared as text in gBASIC code. |
| Dialect odds and ends | `drop table if exists`, quoted identifiers, multi-row `VALUES` and `order by 1` all work. | The corpus probably runs unchanged. Step 0 confirms it statement by statement. |
| Catalog / describe | There is no `pragma table_info` equivalent, and nothing like `sqlite.columns` that describes a query's result without running it. | gdash's own meta table stays the authority for columns (P3). |

## 3. Decisions

### D1. How big is a database? **Ruled: one database per (dashboard, stage), in the tenant's directory**

Each dashboard gets `cache/<dashboard>/draft.gsql` and
`cache/<dashboard>/published.gsql`. The gbasic storage design (§5.1.1a)
suggested one database per deployment or per tenant. This is finer:

- **Isolation by construction.** In a tenant-wide database, every dashboard's
  SQL can name every other dashboard's tables. Dashboards have different view
  groups (§8), so gdash would have to parse and rewrite author SQL and model SQL
  to prevent cross-reads, and one miss would be a disclosure.
- **Author SQL keeps its names.** `from orders` resolves to this dashboard's
  `orders`. Draft and published need the same table names, which also means
  two databases.
- **It keeps every gain the storage design promised:** no attach cap, no
  attach-every-sibling, one owner per open dashboard rather than one per
  dataset.
- **The cost:** one owner process for each dashboard being viewed. Owners
  start in about 20 ms and stop after their linger.

**Tenants use a directory, not a prefix.** A tenant is already a root with
its own cache directory (`gdash_saas_design.md` §1). Its databases are
therefore `<tenant root>/cache/<dashboard>/{draft,published}.gsql`. The SaaS
design rejects the alternative by name ("Why not a prefix, a shared directory,
or a tenant column"): with a name prefix, isolation rests on a string that
every path has to get right; with a directory, it rests on the filesystem.
Single-tenant installs keep the same layout under their one root.

### D2. Sequencing with GDASH-19. **Decided: migrate first**

GDASH-19 has finished step 0, and nothing of it is implemented. Two of its
rulings were written against SQLite:

- `date` is "validated, stored as TEXT", chosen partly because SQLite has no
  date type;
- bounds go in a table beside `_gdash_meta`.

Under G-SQL a native `date` column gives the validation from the engine, and
date comparisons against text now work (§2). Implementing GDASH-19 first would
mean writing date and bounds code twice. GDASH-19 therefore waits at step 0,
and its brief is re-read against G-SQL when this phase is done.

### D3. Param types. **Ruled: params declare a type, and gdash converts the value on arrival**

A param may declare `type`: `string` (the default), `integer`, `number`, `date`
or `money`. gdash converts the value from the page when the request arrives,
before any query runs, and binds the typed value. A value that does not
convert is refused by name.

G-SQL's comparison rule (§2) would accept untyped text. Typed params are still
worth having for two reasons:

- a bad value is refused once, at the door, rather than by each visual query
  separately;
- gdash's own gBASIC code that looks at param values (control state, GDASH-19's
  relative dates) works on real kinds, and does not meet warning 2122.

`user_*` params stay strings. Today's reference params are all strings, so this
costs nothing until a record uses it.

### D4. Money's stored form. **Ruled: `money(<currency>)` columns**

A declared money column becomes `money(<currency>)`. Validation refuses a
`scale` above the currency's storage scale (USD 6, JPY 4).

**Headroom does not change in practice.** The money type already caps
rendering at USD 9.2 trillion (`gdash_record_format.md`, currency range). What
changes is where the cap is hit:

- today the stored value is fine and rendering refuses it;
- after the migration, the refresh refuses a value over the cap;
- a `sum` that overflows raises warning 2112, which gdash runs under
  `on warning stop` and reports as the visual's error.

### D4a. Decimals beyond the declared scale. **Ruled: store exactly, round only for display**

A source value of `1250.7512` for a column declared at scale 2 is stored as
`1250.7512`. `sum` is exact over the true values. The declared `scale` is the
**display** scale, rendered half-even by `money.text(m, scale)`.

- **What is still refused:** text with more decimals than the currency can
  store (a seventh place for USD), by gBASIC's money parser.
- **Why the old rule existed:** §4's "rejected, not rounded" was needed because
  SQLite held whole minor units and had nowhere to put a third digit.
- **The cost, accepted:** a table's rounded rows may not add up exactly to its
  rounded total. That is the honest result. Rounding at import would make the
  stored figures wrong instead.
- **What goes away:** gdash's scale check, and with it all of `to_minor`.

### D5. Undeclared columns. **Ruled**

Under G-SQL a column's type **is a gBASIC kind**, not an SQL type that resembles
one. gdash keeps inferring the kind from the fetched rows: integer-looking
values become `integer`, numeric ones `number`, and everything else `string`.
The source rows arrive as text, and the column's kind converts them (§2).

## 4. The target

- **Layout:**
  - The resolver adds `dataset_db(dashboard, stage)`.
  - A database holds one table per dataset, plus one `_gdash_meta (dataset,
    column_name, kind, currency, scale)` table, where `scale` is the display
    scale.
  - Validation reserves dataset names that start with `_gdash` or end in
    `__staging`.
- **Refresh:**
  1. The child connects to the database and runs `drop table if exists
     <ds>__staging`.
  2. It creates the staging table and inserts rows in transactions of about
     1 000 rows. Every cell is bound as the text the source gave, and the
     column converts it.
  3. It prints its row count and content hash as today.
  4. If the hash moved, the parent runs **one transaction**: drop `<ds>`,
     rename the staging table to `<ds>`, and replace that dataset's
     `_gdash_meta` rows. Then it bumps the version file.
  5. If the hash did not move, or the child failed, the parent drops the
     staging table. The live table is never touched. This is stale-but-coherent,
     with the transaction doing what the rename used to do.
- **Reads:**
  - Every visual query, `describe_datasets`, `sample_column` and
    `select_across` runs inside `begin("read")`.
  - Money comes back as money, and integers come back exact.
  - `money_columns` reads `_gdash_meta` from the same database, so neither the
    schema-qualification trap (G2-3) nor the scale collision (G13-2) can
    happen any more.
- **Ask:**
  - Catalog tables are plain `<dataset>`, not `<ds>.<ds>`.
  - The dialect string becomes G-SQL.
  - The minor-units note and the unit guard's cents-against-dollars clause are
    deleted, because stored values are now amounts: `amount > 1000` means USD
    1000.
- **Owners:**
  - Linger comes from `server.json` (proposed default 30 s), and the suite
    uses `linger: 0`.
  - The scratch-clean assertion also checks that no owner process is left
    serving the temporary root. It checks by path, so the suite never touches
    anyone else's processes.

### What gets deleted

- `to_minor` and its helpers;
- `_ro_uri`, `_attach_one`, `_connect_across` and `attach_limit`, and the
  record validator's 11-dataset rule;
- the `__text` casts and the `exact` argument;
- schema-qualified meta reads;
- `swap`'s file rename for datasets (the version file keeps its rename);
- `load sqlite`;
- the private `gdash_store._connect_across` that `gdash_nlq.bas` reaches
  into today.

## 5. The phase, in order

0. **Step 0. If any check fails, stop.**
   1. Platform: confirm `gbasic --version` reports `0.10.0+<rev>` at or after
      `e902acf`, and record it in the brief. Building gbasic now needs PCRE2
      (`libpcre2-dev`; 10.46 is installed here).
   2. Run all 29 corpus statements against G-SQL and record each outcome.
   3. Confirm `nlq.catalog` accepts tables with no schema.
   4. Confirm the format layer renders through `money.text(m, scale)`.
   5. Check the owner under a `--root` temp dir: where its socket and spill
      files go, and that scratch-clean holds.
   6. Check the owner under the systemd unit (`ProtectSystem=strict`,
      `ReadWritePaths`).
   7. Measure a refresh at 10⁴ and 10⁶ rows. This also gives the
      refresh-duration figure the volumes answer owed.
1. **Tests first.** Pin each of these:
   - swap under a live reader;
   - a failed refresh leaves the old table untouched;
   - a write inside a read query is refused;
   - a value beyond the declared scale is stored exactly, summed exactly and
     displayed half-even;
   - a seventh USD decimal fails the refresh;
   - an integer above 2^53 round-trips;
   - a dashboard with 20 datasets works (the cap is gone);
   - one dashboard's SQL cannot name another dashboard's table;
   - a typed param is converted on arrival, and a malformed one is refused by
     name (D3).
2. Rewrite `gdash_store` against G-SQL, keeping its verbs where they still
   mean something.
3. Rewrite refresh and the refresh child: the staging table, batched inserts,
   and the parent's swap transaction.
4. Render and format: native money through `money.text(m, scale)`, and native
   integers.
5. Record validation: remove the attach cap, reserve the names, check the
   display scale against the currency, and add param types.
6. Ask: the catalog, the dialect, and the unit-guard removals.
7. Convert the reference and fixture SQL. Update `gen_sql_corpus.py`'s store
   entries and regenerate the corpus.
8. Housekeeping: add `gsql` to the shadow guard's list, and update the
   operations guide, the record format and the README.
9. Findings, the DONE note, and the design edits below.

**Deliberately not in this phase:**

- **Bounded-memory refresh.** G5 is ready on G-SQL's side, but gdash's source
  seam returns every row at once, so this is a separate phase on the fetch
  side.
- **Publish carrying draft data across** (G11-11, still unruled).
- **First-class dataset sharing.**
- **Multi-tenancy work** beyond keeping the layout tenant-rooted.

## 6. Design edits owed

- **§3:**
  - "local SQLite files", and the "two dialects" paragraph;
  - the whole *Staging store: SQLite, and why not Postgres* section. Its
    reasoning survives (no service to run, a hermetic suite), but the ruling
    changes.
- **§3 Refresh:** `<dataset>__staging.db` and the rename become the staging
  table and the swap transaction.
- **§4:**
  - "materializes as INTEGER minor units" becomes `money(<currency>)`, stored
    exactly;
  - "rejected, not rounded" becomes stored exactly, with `scale` as the display
    scale rounded half-even (D4a). Refusal is left only where the currency
    itself cannot hold the value;
  - the `decimal_sum` escape hatch goes;
  - "SUM … exact over 64-bit integers" becomes exact as money, up to the
    currency's range.
- **§6:** cache layout `<name>/{published,draft}.gsql`.
- **§9:** `sqlite.columns` becomes a G-SQL ask (P3).
- **CLAUDE.md invariants:** the swap sentence, and the money sentence
  ("INTEGER minor units", "excess decimals are rejected, not rounded").
- **`gdash_saas_design.md`,** where it names dataset files.

## 7. Platform findings and how they landed (gbasic master, 2026-11-03)

- **S1, done.** `cast(m as text)` and `csv.write` keep every digit. `string(m)`
  and `print` show the currency's places on purpose, for a person reading.
  `money.text(m)` is the exact form.
- **S2, done.** A value that rounds to zero shows `0.00`, with no sign.
- **S3, done, as proposed.** When one side of a comparison has a kind and the
  other is text or a parameter, the text is read as that kind, by the reader
  storing uses. Comparisons between kinds that do not compare are still
  refused.
- **S4, answered differently.** In gBASIC itself, `1 = "1"` stays `false`,
  because a variable has no declared kind for the text to be read as. The
  conversion was built, then reverted: it made `=` disagree with `contains`
  and with `[1] = ["1"]`. The silent part is fixed: warning 2122 names
  `number()` and `{number}`. gdash's side of this is D3.
- **Version.** `--version` names the build (`0.10.0+<rev>`), so step 0 records
  it rather than relying on memory.
- **P3, still open.** There is no catalog and no describe-without-execute. This
  replaces the `sqlite.columns` ask. gdash does not need it for this phase.
- *P1 (version pin) is superseded by the version check in step 0. P2 (rendering
  at N places) and P4 (an engine-enforced scale) were withdrawn: `money.text`
  covers P2, and D4a removes the need for P4.*
