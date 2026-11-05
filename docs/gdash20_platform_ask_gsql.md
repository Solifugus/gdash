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

## A1. Every process that can reach a database must find its owner. **Blocks deployment.**

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

## A2. Describing a query without running it, and a table's columns. *Medium.*

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

## A3. Many rows in one round trip. *Low to medium.*

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

## A4. Knowing when an owner has finished. *Low.*

After a 10⁶-row load with `linger: 0`, the program exited and its database
directory could not be removed for a moment: the owner was still writing a
sorted file. A program that deletes a database, or a test that asserts its
scratch directory is clean, has to wait for that.

gdash will wait by matching `--gsql-owner … <path>` in the process table. A
supported form would be better, for example `db.close({ wait: true })` that
returns once an owner stopping at this close has exited, or a way to ask
whether a path has a live owner.
