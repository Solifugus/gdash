# GDASH-9 — ODBC import: phase brief

**Status:** OPEN. Step-0 complete and written up in `gdash9_findings.md`
(G9-1 … G9-5); it passes.
**Extends:** the development plan's "additional source connectors (SQL Server
is the likely first, given demand)", which sat under *Unscheduled,
deliberately*. Scheduled now by the maintainer, with the shape settled: gdash
keeps **one store of its own** and imports from many origins.
**Authority:** `gdash_design.md` outranks this brief.

---

## 1. The shape, restated because it is the point

gdash does not query a source live. A dataset is **fetched on a schedule and
staged into SQLite**, and every visual query runs against the staged copy.
Design §3 settled that: no live dependency, params can be safe, cross-dataset
joins work by ATTACH, and money is exact.

So ODBC is not "another database gdash supports". It is **another origin gdash
imports from**, joining `postgres` behind a seam that already has two
implementations. Nothing about the store changes, and nothing about the record
format changes.

**Excel is not in scope**, ruled out by the maintainer: a spreadsheet is better
imported into a database first. That also keeps the dataset contract intact —
every source remains something you can push a `select` at, so `sql` stays
required and the record format is untouched.

## 2. Scope

### 2.1 The source

`gdash_source_odbc.fetch(profile, sql)`, satisfying the existing seam exactly.
The profile carries a connection string:

```json
"warehouse": { "kind": "odbc",
               "connection": "Driver=ODBC Driver 18 for SQL Server;Server=…;UID=…;PWD=…" }
```

`DSN=name` works too — it is just a connection string — but gdash must not
require a configured DSN, because this host has four drivers and no DSNs and
that is the normal case.

Loaded on its branch only, as `postgres` already is: a hermetic run must not
require the `odbc` module to be present.

### 2.2 Credentials

A connection string is a credential. It lives in `/etc/gdash/connections.json`
at 0600, never in a record, never in argv, never in a log, never in an error
message shown to a viewer. Step-0 found the driver's own message clean (G9-4);
the phase asserts it rather than trusting the next driver to be as careful.

### 2.3 Money, and the types that are not money

The reason this phase can exist is that `DECIMAL`, `NUMERIC` and `BIGINT`
arrive as text (G9-2). The suite asserts that end to end — a money column
through ODBC lands in the same INTEGER minor units as the same column through
Postgres — because "money is exact" is gdash's central claim and a second
importer is a second chance to break it.

### 2.4 Diagnosis

`gdash source check <profile>`, in the shape `gdash auth check` already
established: connect, run a trivial query, and report the driver, whether the
connection worked, and what a column comes back as. It prints no connection
string.

`odbc.drivers()` and `odbc.sources()` make the common failure — "the driver is
not installed on this host" — a sentence rather than a mystery.

### 2.5 Tests

- **Hermetic**: profile validation, the refusals, and the error paths against a
  scripted source. No driver needed.
- **Opt-in, `GDASH_ODBC_TEST=1`**: a real query through the real driver
  manager. Step-0 established this needs **no service** — the SQLite driver
  reads a file — so this runner is cheaper than the Postgres one and should be
  run more often.
- **Parity**: the same fixture data through `postgres` and through `odbc`
  produces the same staged database, which is the assertion that the seam is a
  seam.

## 3. Construction rules

Unchanged, and additionally:

- **No connection string in any output.** Asserted, not intended.
- **The seam is not widened.** If ODBC needs something `fetch` cannot express,
  that is a finding, not a new parameter.

## 4. Done means

1. An ODBC profile refreshes a dataset into the staging store.
2. A money column through ODBC is exact and identical to the same column
   through Postgres.
3. No connection string appears in an error, a log, or a diagnostic.
4. `gdash source check` names the driver and the failure when there is one.
5. The opt-in ODBC runner passes; the hermetic suite is unchanged in shape.
6. Findings recorded; the DONE note names what was not built.

## 5. Deliberately not built

Excel and other file sources (§1). Pushing visual queries to a source — design
§10 defers pass-through and this does not reopen it. Connection pooling: a
refresh is a child process that exits. `odbc.exec`, transactions, and anything
that writes: gdash reads a source and never modifies one. DSN management,
driver installation, and `odbc.ini` — a deployment's job, named in the
operations document.
