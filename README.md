# gdash

A dashboarding web application written in gBASIC.

Dashboards are JSON records. Each names some **datasets** — SQL against an
outside source, fetched on a schedule and staged locally — and some **visuals**
— SQL against the staged copy, rendered as charts, tables and numbers. Only
visual queries take parameters, and the dependency graph between a slicer and
the visuals it affects is derived from the `:name` bindings in the SQL rather
than declared.

Every query runs on the server. The browser receives rendered fragments, never
data and never a connection, which is what makes a user-filtered dashboard over
a shared dataset genuinely safe to expose.

## Try it in five minutes

You need the gBASIC interpreter built from the sibling repo, and either
`GDASH_GBASIC` set to it or `gbasic` on `PATH`. Nothing else — no database, no
network, no display; the quickstart's data is a fixture file.

```sh
export GDASH_GBASIC=~/development/gbasic/gbasic
R=/tmp/gdash-try                     # any directory; --root keeps gdash inside it

mkdir -p $R/lib/dashboards/sales $R/etc
cp dashboards/sales/draft.json $R/lib/dashboards/sales/draft.json
cat > $R/etc/connections.json <<'JSON'
{ "warehouse":  { "kind": "fixture", "path": "fixtures/orders.json" },
  "regionbook": { "kind": "fixture", "path": "fixtures/regions.json" } }
JSON

$GDASH_GBASIC src/gdash_cli.bas --root $R validate sales
$GDASH_GBASIC src/gdash_cli.bas --root $R refresh  sales
$GDASH_GBASIC src/gdash_cli.bas --root $R list
```

Give yourself a login — the password is read from stdin, never from argv,
because argv is world-visible in `ps`:

```sh
$GDASH_GBASIC src/gdash_cli.bas --root $R user add you --admin
```

Then start the server and open <http://127.0.0.1:8780/>:

```sh
GDASH_ROOT=$R $GDASH_GBASIC src/gdash_server.bas
```

The root page lists the dashboards **you** may open, which for a stranger means
only the ones that opted into `access: open`. `dashboards/sales/draft.json` is
the reference record; it is the place to look before writing your own.

### When you publish

Published and draft data are kept apart, so publishing does not carry the
draft's data across — `gdash publish` says so and names the refresh that fills
it. Viewers pin the version they opened and are *offered* a new one rather than
reloaded onto it.

## Running it properly

`make install` puts gdash at FHS paths with systemd units for the server and
the refresh timer. `docs/gdash_operations.md` is the operator's document:
install, backup and restore, TLS, worker sizing with measured numbers, and a
table of what each failure looks like.

**TLS is not available in gdash today.** The platform accepts a certificate and
then serves in cleartext, so gdash refuses to start rather than look encrypted
while it is not. Terminate TLS at a reverse proxy.

## The tests

```sh
tests/run_tests.sh        # hermetic: no network, no database, no display
make check                # the same thing, by another name
```

The suite is hermetic by construction — it runs under `--root` in a temp
directory, and every run ends by asserting it left no scratch and no stray
process. Anything needing a live service is a separate runner behind an
environment variable (`GDASH_POSTGRES_TEST=1`, `GDASH_ODBC_TEST=1`,
`GDASH_LDAP_TEST=1`, `GDASH_FHS_TEST=1`).

## Documentation

| | |
|---|---|
| `docs/gdash_design.md` | the architecture rulings and their reasons — authoritative |
| `docs/gdash_development_plan.md` | the phase roadmap |
| `docs/gdash_record_format.md` | what goes in a dashboard record |
| `docs/gdash_operations.md` | installing, running and recovering it |
| `docs/gdashN_findings.md` | what each phase found, including what it got wrong |
