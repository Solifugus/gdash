# Platform ask: what gdash needs from G-SQL to move onto it

**From:** gdash, GDASH-20 step 0 · **Date:** 2026-11-05 · **Build measured:**
`0.10.0+cac666c`

gdash is moving its staging store from SQLite to G-SQL (gdash
`docs/gsql_migration_plan.md`). Each dashboard gets two databases, one for
draft and one for published. The datasets are tables, and a refresh is a
staging table renamed over the live one in one transaction, under readers in
`begin("read")`. Everything gdash measured works (gdash `gdash20_brief.md`
step 0). This ask lists what is missing in priority order. Only A1 blocks
anything.

## A1. Every process that can reach a database must find its owner. **Done: gbasic `d2e310e`**, measured by gdash under real systemd (361 ms, where `db72b76` stalled 28.5 s).

**The problem.** A client finds a database's owner through a socket in
`$XDG_RUNTIME_DIR/gbasic`, or `/tmp/gbasic-<uid>` when that is unset
(`src/gsql/owner.c:86`). gdash reaches one database from four places: the
server's workers (`gdash.service`), the scheduler's refresh pass and its
children (`gdash-scheduler.service`), and an administrator's CLI.

- System services have no `XDG_RUNTIME_DIR`.
- Both units set `PrivateTmp=true`, which is ordinary hardening. Each unit
  therefore sees its own `/tmp`, and so its own socket directory.

**The consequence.** The scheduler's refresh cannot see the server's owner. It
starts one of its own, which loses the database's lock, and its client retries
a socket it cannot see until the attempts run out. So a refresh fails whenever
a viewer has the dashboard open.

This is not specific to gdash. Any gBASIC service hardened with `PrivateTmp`,
or split across two units, or administered by a person from a shell, has the
same split.

**What gdash cannot do about it.** gBASIC has no `setenv`, and `gsql.connect`
takes no socket location. Setting `XDG_RUNTIME_DIR` in each unit and in the CLI
wrapper is gdash's only lever. It misses anyone who runs the interpreter
directly, and it changes the variable for every other XDG consumer in the
process.

**Two shapes; gbasic's choice:**

1. **Preferred: the database finds its own owner.** The socket, or a pointer
   to it, lives with the database. Whoever can reach the database directory
   can then reach its owner, and the question of which runtime directory
   disappears.
   - **Trust:** the database directory is already mode 0700 (measured:
     `drwx------`), so the trust argument of owner design §3 carries over:
     only the owning user can reach the socket.
   - **The 108-byte `sun_path` limit** is the obvious obstacle for deep paths.
     Binding and connecting relative to a directory descriptor (`fchdir`, or
     `/proc/self/fd/N/…` on Linux) is one way around it.
2. **Fallback: the program says where.** `gsql.connect(path, { runtime_dir:
   d })`, and the same option on a `database` block, with the same checks the
   default gets (a directory, not a link, owned by this user, mode 0700).
   gdash would pass its resolver's `run_dir`. That would also keep the
   hermetic suite's sockets inside its temp root, where today they land in
   the developer's `/run/user/<uid>`.

## A2. Describing a query without running it, and a table's columns. **Done: gbasic `3250863`** (`db.columns(sql)`). Not adopted yet: using it for channel validation is a ruling owed. *Was: medium.*

This is the `sqlite.columns(db, sql)` ask from gdash's design §9, carried over
to the new engine:

- `db.columns(sql)` answers `[{ name, kind }]` for a statement's result
  without executing it;
- the columns of a table and their declared kinds are readable (for example
  `db.columns("select * from t")`, or a catalog verb).

**What it would give gdash:**

- **Load-time red/green, completed.** Every encoding channel is checked
  against a real result column before a dashboard is served. Today that check
  happens at first refresh (design §2).
- **`describe_datasets` without gdash's own meta table** for the columns and
  their kinds. gdash keeps the meta table for the display scale either way.

## A3. Many rows in one round trip. **Done: gbasic `f02455a`** (`db.insert(table, rows)`), adopted by gdash's `materialize`. *Was: low to medium.*

The refresh child inserts a whole dataset through the owner. Measured, at 1 000
rows a transaction:

| rows per statement | 10⁵ rows |
|---|---|
| 1 | 3.6 s |
| 10 | 1.8 s |

At 10⁶ rows with one row a statement, that is 48 s. gdash will batch 10 or so
rows into a multi-row `VALUES` itself.

A verb that takes a table, its columns and an array of row arrays, converting
each value through the column's kind as `INSERT` does, would make a large
refresh mostly the source query's time. It would also give every CSV and
spreadsheet loader in gBASIC the same path. That loader path is new since
45f9fe7 ("G-SQL loading"), so it may already be part of this.

## A4. Knowing when an owner has finished. **Done: gbasic `219ec73`** (`close({ wait })`) and `0424a49` (`gsql.wait_for_owner(path, seconds)`). The second is the one the suite's scratch-clean uses. *Was: low.*

After a 10⁶-row load with `linger: 0`, the program exited and its database
directory could not be removed for a moment: the owner was still writing a
sorted file. A program that deletes a database, or a test that asserts its
scratch directory is clean, has to wait for that.

gdash will wait by matching `--gsql-owner … <path>` in the process table. A
supported form would be better, for example `db.close({ wait: true })` that
returns once an owner stopping at this close has exited, or a way to ask
whether a path has a live owner.

## A5. The dialect gaps an author meets first. **Done: gbasic `0424a49`**, after the maintainer's ruling on spellings: `substring(x, start [, length])`, `extract(part FROM value)`, and `GROUP BY` by position or alias. *Was: medium.* (Added during the build, 2026-11-06.)

Converting gdash's own tests turned these up. Each is something a dashboard
author coming from SQLite or PostgreSQL writes without thinking, and something
a model writing SQL for `ask` reaches for:

- **No substring function.** The function list is `coalesce`, `nullif`,
  `lower`, `upper`, `length`, `char_length`, `abs`, `round`, `trim` and `mod`.
  - The SQLite spelling is refused by name: `substr(month, 6, 2)` gives
    "`substr` is not a G-SQL function".
  - The PostgreSQL forms are refused too: `substring(month from 6 for 2)` is
    a syntax error, and `substring(month, 6, 2)` is not a function.
  - gdash's tests took the month out of `'2026-02'` with `substr`. They now
    use a `CASE`, which works for a fixture and not for real data.
- **`GROUP BY` takes neither an output alias nor a position.**
  - `select <expr> as period ... group by period` is refused with "table
    orders has no column `period`".
  - `group by 1` is refused as "neither grouped by nor inside an aggregate".
  - PostgreSQL and SQLite accept both. `ORDER BY 1` does work. The portable
    alternative is a derived table.
- **Date parts.** There is nothing to take the year or month out of a date,
  in either spelling (`extract(month from d)`, `date_part`). GDASH-19's
  relative date ranges (`mtd`, `last_quarter`) are computed in gBASIC and
  bound as params, so gdash does not need it for those. Authors writing a
  by-month chart over a `date` column will.

gdash is not blocked by any of these. Each costs an author a rewrite and a
model a refused draft. They are listed so the PG∩SQLite measurement
(`gsql_design.md` §4.0) has them, with the corpus showing where each comes
from.

## A6. Trailing zeros are not excess precision. **Done: gbasic `8633507`.** gdash's stopgap is deleted; measured green against live Postgres. (Added during the build, 2026-11-06.)

gBASIC's money text reader counts the characters after the point, not the
significant digits:

```
money.of("USD", "12.345600")      -> 12.345600
money.of("USD", "12.3456000")     -> refused: more decimal places than the currency can store
money.of("USD", "1100.00000000")  -> refused   (an exact whole amount)
```

Storing into a `money(USD)` column goes through the same reader, so the
`insert` is refused as `TYPE`.

**Why it matters.** PostgreSQL renders a `numeric(p, s)` value with exactly `s`
places, and ODBC drivers do the same. Any source money column with more
decimal places than the currency stores (USD six, JPY four) therefore fails
every refresh, even for whole-dollar amounts. `numeric(19,8)` is ordinary in
FX and crypto ledgers. gdash found this once already as G9-6: the same value
was accepted through one origin and refused through another, because one
padded it.

**What gdash does meanwhile.** `gdash_store` strips trailing zeros from money
text before binding it. This is the one piece of `to_minor` that survives, and
it is pinned by `test_store` and by the live Postgres runner. A non-zero digit
past the storage scale is still refused, which is the property that matters.

**The ask.** A money reader that refuses only non-zero digits past the storage
scale: "rejected, not rounded" applied to significant digits. With that, the
stopgap goes.
