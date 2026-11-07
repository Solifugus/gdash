# GDASH-21 — Channels checked against what a query really returns

**Status:** built, at the review boundary (2026-11-07). Opened on the
maintainer's go-ahead, before GDASH-19.
**Authority:** `gdash_design.md` outranks this brief.

## Why this phase exists

Design §2 promises load-time red/green: a dashboard validates completely
before anyone sees it. There was one gap. A channel naming a column the query
does not return was found by whoever opened the dashboard, as an error box in
one visual. Nothing could say what a query returns without running it. G-SQL
can now, with `db.columns(sql)` (GDASH-20 ask A2, gbasic `3250863`): the
columns are described from the plan, with nothing run and no parameter
needed.

## Step 0

- **`db.columns` works through the store.** A query with a `:param` is
  described with no value supplied. Its columns come back in select-list
  order, a plain column carries its kind, and a query that does not compile
  comes back as a value, not a raise.
- **The two limits come from the platform, not gdash.** The table must exist,
  because the columns come from the plan. Computed columns are described as
  `any`. Neither blocks the check; both shape it (record format §6).

## What was built

- `gdash_store.columns(db_path, sql)`: the describe, in a read transaction.
- `gdash_channels.check_channels(rec, db_path)` answers `{ errors, warnings, unchecked }`:
  - **errors:** a query that does not compile; a channel or `formats` key
    naming no returned column; a control's options query that does not
    compile;
  - **warnings:** a currency format over text, a date or a boolean;
  - **not checked:** a visual or control whose dataset has never refreshed.
- `gdash_publish.publish` runs the check against the **draft's** staged data,
  refuses on any error and audits the refusal. It returns the warnings and
  the not-checked items as `notes`, and the CLI prints them.
- `gdash validate` runs the same check and exits 1 on an error.
- `tests/test_channels.bas`, 25 assertions:
  - each refusal, each warning, the not-checked case;
  - publish refusing;
  - publish succeeding once the channel is fixed;
  - a first publish before any refresh still succeeding, with a note.

## Deliberately not built

- **No check at true load time.** Before a first refresh there is nothing to
  plan against.
- **No kind check on computed columns.** The planner reports `any` for them.
- **`ask --promote` does not call the check yet.** A promoted visual's query
  is the one that just ran, so its channels are the columns it returned; the
  check would add nothing there today.
