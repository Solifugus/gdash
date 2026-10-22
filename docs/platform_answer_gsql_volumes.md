# Platform answer: G-Dash's data volumes, for G-SQL's storage design

**From:** gdash · **Date:** 2026-10-21 · **Answers:** `platform_ask_gsql_volumes.md`

## The one thing to know before the numbers

**gdash has no production deployment.** Nothing below comes from a real
customer's data. Every figure is one of three kinds, and each is labelled:

- **measured**: from `gdash_operations.md` §5, which runs one worker against
  the reference dashboard;
- **structural**: a limit the code enforces, which no amount of usage changes;
- **guess**: what gdash is designed for. These are orders of magnitude and should
  be weighted that way.

The reference dashboards (`dashboards/sales`, `dashboards/treasury`) and the
fixtures they refresh from have 2–7 rows per dataset. They pin behaviour, not
volume, so do not treat them as volume samples.

## 1. Rows per dataset, and row width

- **Typical: 10²–10⁴ rows. Largest plausible: ~10⁶. (guess)** gdash is for
  aggregates and summaries, not raw event logs (`gdash_saas_assessment.md` §3B).
  A dataset is usually something like a monthly ledger, positions, FX rates or
  a dimension table.
- **The ceiling is the refresh child's RAM, not disk. (structural)** A refresh
  fetches the whole result set into memory (`got.rows`), plans the columns from
  it, then materializes it. A source table with tens of millions of rows has to
  be aggregated in the dataset SQL before it reaches gdash. The assessment
  names this as the wall a real tenant will probably hit first. No measured
  number for it exists yet.
- **Width: 3–10 columns, mostly short text keys, ISO dates and integers.
  Roughly 50–150 bytes a row. (guess, consistent with the reference
  datasets)** The reference datasets have 3–4 columns each.

## 2. Datasets per deployment, and per query

- **The 11-dataset cap applies per dashboard, not per deployment.
  (structural)** A visual query opens one dataset file and attaches every
  other dataset of *its own dashboard* (`gdash_store.select_rows`). The record
  validator refuses a dashboard with more than `attach_limit() + 1` = 11
  datasets at load time (`gdash_record.bas:243`). Across a whole deployment the
  count is unbounded: N dashboards × their datasets, each in its own file.
- **Without the cap: 2–5 datasets per dashboard, occasionally 15–20. (guess)**
  The reference dashboards have 2 and 3. A dashboard that joins a fact table
  to several dimensions is where 11 starts to bind.
- **Per deployment: tens of dashboards, so 10²–10³ dataset files. (guess)**
  Under the multi-tenant design (`gdash_saas_design.md`) multiply that by the
  number of tenants. Each file is still only ever read alongside its own
  dashboard's siblings.
- **One query touches 1–2 datasets but attaches all of its dashboard's
  datasets. (structural)** It attaches them all because there is no SQL parse
  to say which ones it uses. Of the seven reference visual queries, six read
  one dataset and one joins two. So the cost per query is open + up to 10
  read-only attaches + query + close.

## 3. Refresh

- **Cadence is per dataset:** `manual`, `interval` (`every: <seconds>`) or
  on open with `min_age` (`gdash_sched.bas`). **(structural)** In practice
  the cadence is **minutes to a day**: 5–15 minutes for operational
  figures, nightly for most. **(guess)**
- **Duration of the largest refresh: not measured.** It is dominated by the
  source query and by materializing in the refresh child: reading every row into
  memory, `to_minor` on each money cell, insert, then one rename. For ~10⁵ rows
  the guess is seconds. Measuring this is owed anyway (assessment §3B asks for
  a documented number).
- **Refreshes overlap with dashboard use, by design. (structural)** A refresh
  runs in a child process and writes a staging file. It swaps with one POSIX
  `rename` and bumps the version file afterwards. Readers on the old inode
  finish against the old data (stale-but-coherent, design §3). It is always a
  whole-dataset rewrite. There is no incremental refresh.

## 4. Read load

- **Poll: every open tab hits `GET /d/{name}/version` every 5 s. (measured)**
  The poll reads the version file and the dashboard record. **It does not touch
  a dataset.** At 28 ms a poll, one worker serves ~35 polls/s, so 30 open tabs
  is 6 polls/s and cost nothing measurable.
- **Dataset queries happen on page load and on control changes.** A full page
  queries every visual and costs 57 ms on one worker. **(measured)** One
  worker renders ~20 pages/s in series. A burst of 20 simultaneous loads
  finishes in under 1 s at 1 worker and 0.7 s at 4. **(measured)**
- **Busy moment: 10–20 page loads in a few seconds, at 2–7 visual queries
  each, so ~10–100 dataset queries/s at peak and near zero otherwise.
  (guess, "an office arriving at nine o'clock", operations §5)** A refresh also
  makes every open tab reload its visuals within 5 s. That is a small burst
  proportional to the number of open tabs.

## 5. Query shape

- **Almost all are grouped aggregates over a whole dataset.** Five of seven
  reference visuals are `sum … group by` (one also `where region = :region`,
  one also a two-dataset join), and one is an ungrouped `sum`. The record
  format tells authors to "bucket and aggregate, so the query returns one row
  per thing the eye can see" (`gdash_record_format.md`).
  **(structural for the guidance, guess for real use)**
- **Filtered reads come from params, which only visual queries carry:** an
  equality or range on one or two columns (e.g. `day >= :from`). Sampled reads
  exist only on the `ask` path (`sample_column`: `select distinct … limit n`)
  and in `describe_datasets`.
- **Result size: 1–100 rows, typically under 50.** A detail table may return a
  few hundred. **(guess)** Nothing caps a visual query's result. The cap is
  whatever the author's SQL says.

So the workload is full scans or small group-bys over small-to-medium
read-only files, with no point-lookup traffic to speak of. An index matters
much less than scanning fast and opening/attaching cheaply.

## 6. Money and large integers

- **Share: in the reference dashboards 5 of 16 dataset columns are money
  (31%). Expect 10–30% in real dashboards. (guess)** The reference set leans
  on money because it exists to exercise money. Exact integers above 2^53 are
  rare in practice: IDs and the occasional large count.
- **What the boundary costs today: (structural)**
  - *On write:* `to_minor` turns each money cell's decimal text into an
    integer at its column's scale, and rejects excess decimals rather than
    rounding. The scale is recorded per column in `_gdash_meta`.
  - *On read:* any column that must stay exact is wrapped in
    `select *, cast(col as text) as col__text from ( … )`. The render layer
    then calls `money_columns`, which opens the dataset again and attaches
    its siblings, to read each `_gdash_meta`.
  - *In meaning:* stored values are minor units, so the model-written SQL in
    `ask` compares cents to dollars, and gdash has to warn about it
    (`gdash_operations.md` §6). A native decimal/money type with its scale
    stored in the column would remove all three parts, and the warning too.

## 7. What G-Dash wants that SQLite does not give it

In order of how much each would change gdash:

1. **Money as a typed value with its scale, end to end.** That covers storage,
   arithmetic (`sum` exact at any size) and the result handed back to gBASIC,
   so `to_minor`, `_gdash_meta` scales, the `__text` casts and the minor-unit
   note in `ask` all go away.
2. **Reading across many read-only dataset files with no fixed cap, or with
   cheap lazy attach.** Ideally a query attaches only the files it names
   rather than every sibling. That would also remove the 11-dataset
   validator rule.
3. **Bounded-memory materialization.** Streaming rows from the source into the
   staging file (gdash's side of the seam, `fetch` → `rows`, currently
   returns everything at once) moves the dataset ceiling from RAM to disk.
   This is partly gdash's problem, but the engine needs an append path that
   does not want the whole set up front.
4. **Not wanted: partial or incremental refresh.** Whole-file replace by
   atomic rename is the coherence model (design §3), and gdash would rather
   keep it than gain in-place updates. G-SQL only needs to keep it cheap:
   writing a fresh file sequentially and opening a file that was just renamed
   in, without a cache tied to the inode it replaced.
5. **Cheap open per request.** Workers share no in-memory state, so every
   visual query opens and closes its own connection and attaches. Open and
   attach costs therefore count for as much as query speed.
