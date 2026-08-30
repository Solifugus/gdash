' gdash — refresh child.
'
' Runs as a separate process (design §3). Its whole job is to block: read the
' job file, fetch from the source, write the staging file, exit. It never
' touches the live dataset file -- the parent owns the swap -- so a child that
' dies or hangs leaves the previous data untouched.
'
' The job file carries the connection profile and is mode 0600. Credentials
' never appear in argv, where any user on the box could read them from ps.

program main(args)
    load gdash_store from "gdash_store.bas"
    load gdash_source_fixture from "gdash_source_fixture.bas"

    if count(args) < 1 then
        print to error "usage: gdash_refresh_child <job-file>"
        exit(2)
    end if

    jf {file} = args[0]
    if not exists(jf) then
        print to error "job file not found: " + args[0]
        exit(2)
    end if
    parsed = try_decode(read(jf))
    if not parsed.ok then
        print to error "job file is not valid JSON: " + string(parsed.message)
        exit(2)
    end if
    job = parsed.value

    profile = job["profile"]
    kind = profile["kind"]

    if kind = "fixture" then
        got = gdash_source_fixture.fetch(profile, job["sql"])
    else if kind = "postgres" then
        ' Loaded only on the branch that needs it: a hermetic run must not
        ' require the pg module to be present or a server to exist.
        load gdash_source_pg from "gdash_source_pg.bas"
        got = gdash_source_pg.fetch(profile, job["sql"])
    else
        print to error "unknown profile kind: " + string(kind)
        exit(3)
    end if

    if not got.ok then
        print to error got.message
        exit(4)
    end if

    plan = gdash_store.plan_columns(got.columns, got.rows, job["columns"])

    wrote = gdash_store.materialize(job["staging"], job["table"], plan, got.rows)
    if not wrote.ok then
        print to error wrote.message
        exit(6)
    end if

    ' The parent compares this against the hash it recorded last time and
    ' skips the swap when nothing moved. Computed here because this is where
    ' the fetched rows are; the parent only ever sees a staging file, and two
    ' SQLite files with identical content are not necessarily identical bytes.
    print "rows=" + string(count(got.rows))
    print "hash=" + gdash_store.content_hash(got.columns, got.rows)
    exit(0)
end program
