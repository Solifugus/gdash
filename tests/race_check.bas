' Reads a staged dataset directly, for the concurrency runner.
'
' The invariant design §2 states is that a swap is a single POSIX rename and
' the version bumps after, so a reader sees one whole version or another --
' never a half-written one. This is the reader.

' Bound out so the guard cannot outlive the read it is guarding.
function read_count(dbpath, dataset)
    load gdash_store from "../src/gdash_store.bas"
    on error goto next
    got = gdash_store.select_rows(dbpath, "select count(*) as n from " + dataset, {}, [], {})
    if error then
        return -1
    end if
    if count(got.rows) = 0 then
        return -1
    end if
    return got.rows[0]["n"]
end function

program main(args)
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_store from "../src/gdash_store.bas"

    p = gdash_paths.roles(args[0])
    dashboard = args[1]
    dataset = args[2]
    dbpath = gdash_paths.dataset_db(p, dashboard, "draft", dataset)
    vfile = gdash_paths.version_file(p, dashboard, "draft")

    ' The guard covers the READ and nothing else. `on error goto next` is
    ' frame-scoped, so leaving it in force over the lines below would swallow a
    ' mistake in this file and let the program exit 0 -- which is exactly what
    ' the first draft did, reporting success while printing a runtime error.
    n = read_count(dbpath, dataset)
    if n < 0 then
        print("READ FAILED")
        exit(1)
    end if
    print("rows=" + string(n) + " version=" + string(gdash_store.read_version(vfile)))
    exit(0)
end program
