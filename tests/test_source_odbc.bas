' The ODBC origin, up to the wire.
'
' Everything here runs on a host with no drivers at all: the module loads
' `odbc` inside the functions that need it, so the profile handling and the
' refusals are ordinary hermetic code. What needs a driver manager is in
' tests/run_odbc.sh, which is opt-in and cheap.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_source_odbc from "../src/gdash_source_odbc.bas"

    s = gdash_test.suite("source-odbc")

    ' --- how a profile names its target ---------------------------------
    '
    ' A host may have drivers and no DSNs -- which is the normal case, not the
    ' exception (finding G9-3) -- so a driver-and-options string must work
    ' without anything configured in odbc.ini.
    s = gdash_test.eq(s, gdash_source_odbc.connection_string({ connection: "Driver=SQLite3;Database=/tmp/x.db" }), "Driver=SQLite3;Database=/tmp/x.db", "a connection string is passed through unchanged")
    s = gdash_test.eq(s, gdash_source_odbc.connection_string({ dsn: "warehouse" }), "DSN=warehouse", "a dsn becomes one")
    s = gdash_test.eq(s, gdash_source_odbc.connection_string({ connection: "Driver=X", dsn: "warehouse" }), "Driver=X", "an explicit connection wins over a dsn")
    s = gdash_test.eq(s, gdash_source_odbc.connection_string({}), "", "a profile naming neither yields nothing")
    s = gdash_test.eq(s, gdash_source_odbc.connection_string({ connection: "   " }), "", "and neither does whitespace")
    s = gdash_test.eq(s, gdash_source_odbc.connection_string({ connection: "  Driver=X  " }), "Driver=X", "a target is trimmed")

    ' --- a profile that names nothing is refused before any driver is asked --
    got = gdash_source_odbc.fetch({}, "select 1", 0)
    s = gdash_test.ok(s, not got.ok, "a profile with no target does not reach a driver")
    s = gdash_test.contains_text(s, got.message, "neither 'connection' nor 'dsn'", "and says which keys it wanted")
    s = gdash_test.eq(s, count(got.rows), 0, "with no rows")
    s = gdash_test.eq(s, count(got.columns), 0, "and no columns")

    ' --- THE CONNECTION STRING IS A CREDENTIAL --------------------------
    '
    ' It carries PWD=. Nothing here interpolates a profile into a message, and
    ' this asserts the result rather than the intention -- the live runner
    ' asserts the same thing about the driver's own message, because a driver
    ' is third-party code.
    secret = "Driver=NoSuchDriverAnywhere;UID=app;PWD=hunter2-must-not-appear"
    leaky = gdash_source_odbc.fetch({ connection: secret }, "select 1", 0)
    s = gdash_test.ok(s, not leaky.ok, "an unusable driver fails")
    s = gdash_test.ok(s, not contains(leaky.message, "hunter2-must-not-appear"), "and the password is not in the message")
    s = gdash_test.ok(s, not contains(leaky.message, "PWD="), "nor any part of the connection string")

    ' A host with no drivers reports none rather than raising: the diagnostic
    ' has to work on the machine where nothing is installed, because that is
    ' the machine where somebody is asking why it does not work.
    s = gdash_test.ok(s, type(gdash_source_odbc.describe_drivers()) = "array", "the driver list is a list, whatever the host has")
    s = gdash_test.ok(s, type(gdash_source_odbc.describe_sources()) = "array", "and so is the DSN list")

    exit(gdash_test.report(s))
end program
