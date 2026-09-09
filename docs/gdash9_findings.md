# GDASH-9 — Findings

**Status:** step-0 complete. It passes, and the two things that could have
stopped the phase — money precision and a way to test — both hold.
**Platform:** gBASIC `ca5df46`, `odbc` native over unixODBC.

---

## G9-1 — the `odbc` module is the shape gdash's source seam already takes

```
odbc.connect(connection_string)
odbc.query(connection, sql[, params])   -> array of records
odbc.close(connection)
odbc.drivers()  odbc.sources()
```

gdash's seam is `fetch(profile, sql) -> { ok, columns, rows, message }` with
rows as arrays of strings. `gdash_source_pg` is 51 lines against that
contract; an ODBC source is the same shape with a connection string in place
of a host record.

The reference says the module is verified against SQL Server 2025, MariaDB
11.8 and SQLite, "the same fixtures, one connection string apart".

## G9-2 — money survives, which was the one thing that could have ended the phase

gdash's central invariant is exact money: decimals are carried as text into
INTEGER minor units and never become floats (design §4). An importer that lost
precision would be worse than no importer.

The cookbook is explicit — "Money and big integers come back as STRINGS, on
purpose", because a gBASIC number is a double and `DECIMAL(19,4)` does not fit
in fifteen significant digits. Verified rather than read, through a real driver
against a real database:

```
amount = 900.25            type=string
bigint = 12                type=string
```

`pg` already answers `numeric` and `bigint` this way, so gdash's existing money
path needs no special case: the convention is the same one it was built on.

## G9-3 — this host can test ODBC live, with no server at all

```
drivers: SQLite, SQLite3, MariaDB Unicode, FreeTDS
dsns: 0
```

Four drivers installed, no DSNs configured. That matters more than it looks:

- **The SQLite driver makes a live ODBC test need no service.** A file, a
  connection string, and the real driver manager — so the opt-in runner
  exercises the actual ODBC path without Postgres's or LDAP's setup cost.
- **MariaDB and FreeTDS are there** for a real client/server case in a
  container, if the phase wants one.
- **No DSNs.** gdash must therefore support a driver-and-options connection
  string, not just `DSN=name`. A deployment that has DSNs configured can still
  use them; one that has not must not be stuck.

## G9-4 — a failed connection does not leak the password

The profile carries a connection string, and a connection string carries
`PWD=`. `gdash_source_pg` already avoids interpolating a profile into its error
message for exactly this reason. The question was whether the driver's own
message would do it instead:

```
odbc connection failed: [HY000] [ma-3.2.6]Can't connect to server on '127.0.0.1' (115)
leaks the password: false
```

It names the host and the driver's code. **This is checked, not assumed, and
the phase will assert it** — a driver is third-party code and the next one may
be less careful, so the assertion belongs in the suite rather than in a note.

## G9-5 — a correction to something I said out loud

While probing, two guarded failures in one frame raised uncaught and I read it
as "`on error goto next` guards one operation". That is wrong, and the
reference is precise:

> **One pending error at a time.** A raise arriving while an unacknowledged
> error is pending is *not* absorbed — it escapes the frame as if unhandled.
> Check promptly.

So the rule is *check before the next one can fire*. gdash's pattern — guard,
act, `if error then return` — complies everywhere, and the probe that misled me
simply never checked between two failures. Recorded because a wrong rule about
error handling would have had me "fixing" correct code across sixteen modules.

## G9-6 — trailing zeros were counted as excess precision, and two origins disagreed because of it

Found by the parity test before it was even green — which is the argument for
having one.

The same source value staged fine through ODBC and was **refused** through the
fixture source:

```
refresh failed: value '1250.7500' has 4 decimal places; column scale is 2
                (rejected, not rounded)
```

Neither origin was wrong. They rendered the same number differently: a
`decimal(19,4)` column reaches gdash as `"1250.7500"` from a text-faithful
source and as `"1250.75"` from an ODBC driver, which drops trailing zeros.
Verified that the driver drops nothing else:

```
decimal col: '1250.75'              text col: '1250.7500'
decimal col: '1250.7512'            text col: '1250.7512'
decimal col: '1234567890123456789'  text col: '1234567890123456789'
```

Significant digits survive, and so does a nineteen-digit integer — far past
what a double holds.

**The defect was gdash's.** `gdash_store` compared `len(frac) > scale` —
*characters* after the point, not significant ones. `1250.7500` at scale 2 is
exactly 1250.75 and loses nothing by becoming `125075`, and refusing it refuses
the most ordinary money column there is: a `numeric(19,4)` reported in cents.
Design §4 says "excess decimals are rejected, not rounded"; what it means by
excess is significant, and the code meant textual.

Trailing zeros are now stripped before the comparison. `1250.7512` at scale 2 is
still refused, which is the property that matters, and the Postgres runner still
passes 8/8 — it is the origin most likely to render the trailing zeros that
would have hit this in production.

**This is what a second implementation of a seam is for.** The bug had been
there since GDASH-0 and no single-origin test could see it: it takes two
renderings of one value to notice that the check was reading the rendering.
