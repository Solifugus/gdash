# GDASH-9 — ODBC import: phase brief

**Status:** COMPLETE. All six §4 criteria met. Findings in
`gdash9_findings.md` (G9-1 … G9-6); DONE note in §6.
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

## 6. DONE note

**28 suites — green from a clean checkout**; live Postgres 8/8; live LDAP 49
plus 16 over HTTP; live ODBC 12; the FHS runner 22.

All six §4 criteria met.

**Built:** `gdash_source_odbc` against the existing seam unchanged; the `odbc`
branch in the refresh child, loaded only when used; `gdash source check`;
`tests/run_odbc.sh`; hermetic coverage of everything up to the wire; and the
record-format and operations entries, including the driver-per-vendor
dependency an operator has to install themselves.

**What the phase found:** `gdash_store` counted **characters** after the
decimal point rather than significant digits, so `1250.7500` at scale 2 was
refused though it loses nothing — a `numeric(19,4)` reported in cents, which is
the most ordinary money column there is (G9-6). Present since GDASH-0 and
invisible to every single-origin test: it took two renderings of one value to
see that the check was reading the rendering. Postgres is the origin most
likely to have hit it in production.

**The seam did not move.** `fetch(profile, sql) -> { ok, columns, rows,
message }` absorbed a second real origin with no new parameter, which is the
evidence that it was a seam rather than a shape fitted to one implementation.

**Deliberately not built** — §5 stands, and additionally:

- **No parity test against Postgres itself.** Parity is asserted between ODBC
  and the fixture source, which needs no server and runs in the cheap runner;
  the live-Postgres runner covers the pg path separately. Comparing two live
  services in one run would be the most expensive test in the suite for a
  fact both halves already assert.
- **No driver-specific handling of any kind.** gdash passes a connection
  string to the driver manager and reads back text. If a driver needs coaxing,
  that is `odbc.ini`, not gdash.
- **`gdash source check` only checks ODBC profiles.** A Postgres profile is
  exercised by a refresh, and adding a second connect path to diagnose it
  would be a second place the connection logic lives.

## 5. Deliberately not built

Excel and other file sources (§1). Pushing visual queries to a source — design
§10 defers pass-through and this does not reopen it. Connection pooling: a
refresh is a child process that exits. `odbc.exec`, transactions, and anything
that writes: gdash reads a source and never modifies one. DSN management,
driver installation, and `odbc.ini` — a deployment's job, named in the
operations document.
