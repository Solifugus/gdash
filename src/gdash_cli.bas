' gdash — command line.
'
' usage:
'   gdash_cli.bas --root <dir> validate <dashboard>
'   gdash_cli.bas --root <dir> refresh  <dashboard> [dataset]
'   gdash_cli.bas --root <dir> schedule
'
' Authoring in this phase is the record file itself (design §10), so the CLI
' is what an author uses to check a record and pull data.
'
' `refresh` is a person asking, so it is always a manual trigger and always
' operates on the DRAFT -- which is the only way a draft ever refreshes
' (design §3). `schedule` runs one policy pass over every published
' dashboard; gdash_scheduler.bas is that pass on a period.

program main(args)
    load gdash_paths from "gdash_paths.bas"
    load gdash_record from "gdash_record.bas"
    load gdash_refresh from "gdash_refresh.bas"

    p = gdash_paths.from_args(args)

    verb = ""
    rest = []
    i = 0
    while i < count(args)
        a = args[i]
        if a = "--root" then
            i += 2
        else if verb = "" then
            verb = a
            i += 1
        else
            rest = concat(rest, [a])
            i += 1
        end if
    end while

    if verb = "" then
        print to error "usage: gdash --root <dir> validate|refresh <dashboard> [dataset]"
        print to error "       gdash --root <dir> schedule"
        exit(2)
    end if

    ' One pass, then exit. A cron entry and gdash_scheduler.bas are the same
    ' code path; there is no server-side timer to hang either on (finding
    ' G2-1).
    if verb = "schedule" then
        result = gdash_refresh.pass(p)
        j = 0
        while j < count(result.notes)
            print(result.notes[j])
            j += 1
        end while
        print("schedule: " + string(result.checked) + " checked, " + string(result.refreshed) + " refreshed, " + string(result.unchanged) + " unchanged, " + string(result.failed) + " failed")
        if result.failed > 0 then
            exit(1)
        end if
        exit(0)
    end if

    if count(rest) < 1 then
        print to error "which dashboard?"
        exit(2)
    end if
    name = rest[0]

    loaded = gdash_record.load_file(gdash_paths.record_file(p, name))

    if verb = "validate" then
        if loaded.ok then
            print("ok: " + name + " validates")
            exit(0)
        end if
        j = 0
        while j < count(loaded.errors)
            print to error "error: " + loaded.errors[j]
            j += 1
        end while
        exit(1)
    end if

    if verb = "refresh" then
        if not loaded.ok then
            ' A dashboard validates completely before any source database is
            ' contacted (design §1).
            j = 0
            while j < count(loaded.errors)
                print to error "error: " + loaded.errors[j]
                j += 1
            end while
            exit(1)
        end if
        rec = loaded.record
        profiles = gdash_refresh.load_profiles(p)

        targets = keys(rec["datasets"])
        if count(rest) > 1 then
            targets = [rest[1]]
        end if

        j = 0
        while j < count(targets)
            dn = targets[j]
            ds = rec["datasets"][dn]
            if is_unknown(ds) then
                print to error "no such dataset: " + dn
                exit(1)
            end if
            prof = profiles[ds["profile"]]
            if is_unknown(prof) then
                print to error "no connection profile named '" + string(ds["profile"]) + "'"
                exit(1)
            end if
            r = gdash_refresh.run(p, name, "draft", rec, dn, prof, "manual")
            if not r.ok then
                print to error "refresh failed: " + r.message
                exit(1)
            end if
            if r.unchanged then
                print("unchanged " + name + "." + dn + " (" + string(r.rows) + " rows, version " + string(r.version) + " stands)")
            else
                print("refreshed " + name + "." + dn + " -> version " + string(r.version))
            end if
            j += 1
        end while
        exit(0)
    end if

    print to error "unknown command: " + verb
    exit(2)
end program
