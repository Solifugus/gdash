' gdash — command line.
'
' usage:
'   gdash_cli.bas --root <dir> validate <dashboard>
'   gdash_cli.bas --root <dir> refresh  <dashboard> [dataset] [--draft]
'   gdash_cli.bas --root <dir> schedule
'   gdash_cli.bas --root <dir> publish   <dashboard>
'   gdash_cli.bas --root <dir> rollback  <dashboard> [snapshot]
'   gdash_cli.bas --root <dir> snapshots <dashboard>
'   gdash_cli.bas --root <dir> diff      <dashboard> [from] [to]
'   gdash_cli.bas --root <dir> user list
'   gdash_cli.bas --root <dir> user add    <name> [--admin] [--email E] [--groups a,b]
'   gdash_cli.bas --root <dir> user passwd <name>
'   gdash_cli.bas --root <dir> user groups <name> a,b
'   gdash_cli.bas --root <dir> user disable|enable|remove <name>
'
' The password is read from STDIN, never from argv and never from the
' environment: argv is world-visible in ps, and an environment variable
' outlives the command that set it.
'
' Authoring in this phase is the record file itself (design §10), so the CLI
' is what an author uses to check a record and pull data.
'
' `refresh` is a person asking, so it is always a manual trigger. It operates
' on whatever the dashboard SERVES -- the published data when the dashboard is
' published, the draft when it is not -- because a published dashboard whose
' dataset is `manual` would otherwise have no way to be refreshed at all
' outside the browser. `--draft` forces the draft, which is what an author
' wants while editing. `schedule` runs one policy pass over every published
' dashboard; gdash_scheduler.bas is that pass on a period.

program main(args)
    load gdash_paths from "gdash_paths.bas"
    load gdash_record from "gdash_record.bas"
    load gdash_refresh from "gdash_refresh.bas"
    load gdash_publish from "gdash_publish.bas"
    load gdash_diff from "gdash_diff.bas"
    load gdash_users from "gdash_users.bas"

    p = gdash_paths.from_args(args)

    verb = ""
    rest = []
    force_draft = false
    i = 0
    while i < count(args)
        a = args[i]
        if a = "--draft" then
            force_draft = true
            i += 1
        else if a = "--root" then
            i += 2
        else if verb = "" then
            verb = a
            i += 1
        else
            rest = concat(rest, [a])
            i += 1
        end if
    end while

    ' --- accounts ---------------------------------------------------------
    if verb = "user" then
        opt_admin = false
        opt_email = ""
        opt_groups = ""
        k = 0
        while k < count(args)
            if args[k] = "--admin" then
                opt_admin = true
            end if
            if args[k] = "--email" and k + 1 < count(args) then
                opt_email = args[k + 1]
            end if
            if args[k] = "--groups" and k + 1 < count(args) then
                opt_groups = args[k + 1]
            end if
            k += 1
        end while

        loaded_users = gdash_users.load_users(p)
        if not loaded_users.ok then
            print to error loaded_users.message
            exit(1)
        end if
        db = loaded_users.db

        sub = ""
        if count(rest) > 0 then
            sub = rest[0]
        end if
        who = ""
        if count(rest) > 1 then
            who = rest[1]
        end if

        if sub = "list" then
            have = gdash_users.names(db)
            if count(have) = 0 then
                print("no users yet -- create the first with: gdash user add <name> --admin")
                exit(0)
            end if
            j = 0
            while j < count(have)
                u = gdash_users.lookup(db, have[j])
                marks = []
                if u["admin"] = true then
                    marks = concat(marks, ["admin"])
                end if
                if u["disabled"] = true then
                    marks = concat(marks, ["disabled"])
                end if
                tail = ""
                if count(marks) > 0 then
                    tail = " [" + join(marks, ", ") + "]"
                end if
                print(have[j] + "  groups: " + join(gdash_users.groups_of(u), ",") + tail)
                j += 1
            end while
            exit(0)
        end if

        if who = "" then
            print to error "which user?"
            exit(2)
        end if
        existing = gdash_users.lookup(db, who)

        if sub = "add" or sub = "passwd" then
            if sub = "add" and not is_unknown(existing) then
                print to error "user '" + who + "' already exists; use passwd or groups"
                exit(1)
            end if
            if sub = "passwd" and is_unknown(existing) then
                print to error "no such user: " + who
                exit(1)
            end if
            pw = input("password for " + who + ": ")
            again = input("again: ")
            if pw != again then
                print to error "those did not match; nothing was changed"
                exit(1)
            end if
            if trim(pw) = "" then
                print to error "an empty password is not a password"
                exit(1)
            end if
            groups = []
            email = opt_email
            admin = opt_admin
            disabled = false
            if not is_unknown(existing) then
                groups = gdash_users.groups_of(existing)
                if email = "" then
                    email = gdash_users.email_of(existing)
                end if
                if sub = "passwd" then
                    admin = existing["admin"] = true
                    disabled = existing["disabled"] = true
                end if
            end if
            if opt_groups != "" then
                groups = split(opt_groups, ",")
            end if
            db = gdash_users.upsert(db, who, password_hash(pw), email, groups, admin, disabled)
            if not gdash_users.save(p, db) then
                print to error "could not write the user file"
                exit(1)
            end if
            print("ok: " + who)
            exit(0)
        end if

        if is_unknown(existing) then
            print to error "no such user: " + who
            exit(1)
        end if

        if sub = "groups" then
            g = []
            if count(rest) > 2 then
                g = split(rest[2], ",")
            end if
            db = gdash_users.upsert(db, who, "", gdash_users.email_of(existing), g, existing["admin"] = true, existing["disabled"] = true)
        else if sub = "disable" then
            db = gdash_users.upsert(db, who, "", gdash_users.email_of(existing), gdash_users.groups_of(existing), existing["admin"] = true, true)
        else if sub = "enable" then
            db = gdash_users.upsert(db, who, "", gdash_users.email_of(existing), gdash_users.groups_of(existing), existing["admin"] = true, false)
        else if sub = "remove" then
            db = gdash_users.drop_user(db, who)
        else
            print to error "unknown user command: " + sub
            exit(2)
        end if

        if not gdash_users.save(p, db) then
            print to error "could not write the user file"
            exit(1)
        end if
        print("ok: " + who)
        exit(0)
    end if

    if verb = "" then
        print to error "usage: gdash --root <dir> validate|refresh <dashboard> [dataset]"
        print to error "       gdash --root <dir> publish|rollback|snapshots|diff <dashboard> [...]"
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

    ' --- the §7 lifecycle. These run before the draft is loaded, because
    ' publish must be able to REFUSE an invalid draft and say why, and the
    ' other three do not read the draft at all. ---

    if verb = "publish" then
        r = gdash_publish.publish(p, name)
        if not r.ok then
            print to error r.message
            j = 0
            while j < count(r.errors)
                print to error "error: " + r.errors[j]
                j += 1
            end while
            exit(1)
        end if
        print("published " + name + " as " + r.snapshot)
        exit(0)
    end if

    if verb = "rollback" then
        target = ""
        if count(rest) > 1 then
            target = rest[1]
        end if
        r = gdash_publish.rollback(p, name, target)
        if not r.ok then
            print to error r.message
            exit(1)
        end if
        print("rolled " + name + " back to " + r.snapshot)
        exit(0)
    end if

    if verb = "snapshots" then
        have = gdash_publish.snapshots(p, name)
        if count(have) = 0 then
            print(name + " has never been published")
            exit(0)
        end if
        at = gdash_paths.read_pointer(p, name)
        j = 0
        while j < count(have)
            mark = "  "
            if have[j] = at then
                mark = "* "
            end if
            print(mark + have[j])
            j += 1
        end while
        exit(0)
    end if

    if verb = "diff" then
        have = gdash_publish.snapshots(p, name)
        if count(have) < 1 then
            print to error name + " has no snapshots to compare"
            exit(1)
        end if
        ' Default: the version now in force against the one before it -- the
        ' question design §7 poses, which is what changed since last time.
        to_leaf = gdash_paths.read_pointer(p, name)
        if to_leaf = "" then
            to_leaf = have[count(have) - 1]
        end if
        from_leaf = ""
        k = 0
        while k < count(have)
            if have[k] = to_leaf and k > 0 then
                from_leaf = have[k - 1]
            end if
            k += 1
        end while
        if count(rest) > 1 then
            from_leaf = rest[1]
        end if
        if count(rest) > 2 then
            to_leaf = rest[2]
        end if
        if from_leaf = "" then
            print to error name + " has only one snapshot; there is nothing to compare it with"
            exit(1)
        end if
        a = gdash_publish.snapshot_text(p, name, from_leaf)
        if is_unknown(a) then
            print to error "no such snapshot: " + from_leaf
            exit(1)
        end if
        b = gdash_publish.snapshot_text(p, name, to_leaf)
        if is_unknown(b) then
            print to error "no such snapshot: " + to_leaf
            exit(1)
        end if
        body = gdash_diff.unified(string(a), string(b), from_leaf, to_leaf, 3)
        if body = "" then
            print(from_leaf + " and " + to_leaf + " are identical")
            exit(0)
        end if
        print(body)
        exit(0)
    end if

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
        ' Refresh what the dashboard serves, not what it is being edited into.
        target = gdash_paths.publication(p, name)
        if force_draft then
            target = { mode: "draft", record_file: gdash_paths.record_file(p, name), published: false, snapshot: "" }
        end if
        loaded = gdash_record.load_file(target.record_file)
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
            r = gdash_refresh.run(p, name, target.mode, rec, dn, prof, "manual")
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
