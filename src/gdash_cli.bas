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
    load gdash_shadow from "gdash_shadow.bas"
    load gdash_paths from "gdash_paths.bas"
    load gdash_record from "gdash_record.bas"
    load gdash_refresh from "gdash_refresh.bas"
    load gdash_publish from "gdash_publish.bas"
    load gdash_diff from "gdash_diff.bas"
    load gdash_users from "gdash_users.bas"
    load gdash_authcfg from "gdash_authcfg.bas"
    load gdash_auth from "gdash_auth.bas"
    load gdash_auth_ldap from "gdash_auth_ldap.bas"
    load gdash_source_odbc from "gdash_source_odbc.bas"
    load gdash_sched from "gdash_sched.bas"
    load gdash_format from "gdash_format.bas"

    ' A bare-name `load` searches THIS directory, recursively, before the
    ' stdlib, so a stray crypto.bas here would be the password hasher. Loads
    ' resolve before the body runs, so this cannot prevent the load -- but a
    ' gBASIC library body defines functions rather than running them, so a
    ' shadow is inert until something calls it, and gdash refuses first.
    shadows = gdash_shadow.enforce()

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
        else if a = "--help" or a = "-h" or a = "help" then
            ' Not a verb. Without this, `--help` fell through to the verb slot
            ' and gdash answered "which dashboard?", which is the least useful
            ' thing it could have said to somebody who had just asked for help.
            verb = ""
            rest = []
            i = count(args)
        else if verb = "" then
            verb = a
            i += 1
        else
            rest = concat(rest, [a])
            i += 1
        end if
    end while

    ' --- a source, checked ------------------------------------------------
    '
    ' The shape `auth check` established: connect, ask the smallest possible
    ' question, and say what came back. Without it the first evidence that a
    ' driver is missing is a refresh failing at 3am with a SQLSTATE.
    '
    ' It prints NO CONNECTION STRING. That string carries PWD=.
    if verb = "source" then
        sub = ""
        if count(rest) > 0 then
            sub = rest[0]
        end if
        if sub != "check" then
            print to error "usage: gdash --root <dir> source check [profile]"
            exit(2)
        end if
        profiles = gdash_refresh.load_profiles(p)
        have = sort(keys(profiles))
        if count(rest) < 2 then
            if count(have) = 0 then
                print("no connection profiles in " + gdash_paths.connections_file(p))
                exit(0)
            end if
            j = 0
            while j < count(have)
                print(have[j] + "  kind: " + string(default(profiles[have[j]]["kind"], "(none)")))
                j += 1
            end while
            print("")
            print("give a profile to test it: gdash source check <profile>")
            exit(0)
        end if
        pname = rest[1]
        prof = profiles[pname]
        if is_unknown(prof) then
            print to error "no connection profile named '" + pname + "'"
            print to error "profiles are defined in " + gdash_paths.connections_file(p)
            exit(1)
        end if
        kind = string(default(prof["kind"], ""))
        print(pname + ": kind " + kind)
        if kind != "odbc" then
            print("  only 'odbc' profiles can be checked from here; a '" + kind + "' profile is exercised by a refresh")
            exit(0)
        end if
        drivers = gdash_source_odbc.describe_drivers()
        print("  drivers this host can load: " + join(drivers, ", "))
        dsns = gdash_source_odbc.describe_sources()
        if count(dsns) > 0 then
            print("  configured DSNs: " + join(dsns, ", "))
        else
            print("  configured DSNs: none -- name a Driver= in the connection string")
        end if
        got = gdash_source_odbc.fetch(prof, "select 1 as probe")
        if not got.ok then
            print to error "  FAILED: " + got.message
            exit(1)
        end if
        print("  connected, and a trivial query answered " + string(count(got.rows)) + " row(s)")
        print("  values arrive as: " + type(got.rows[0][0]) + " (money depends on this being text)")
        exit(0)
    end if

    ' --- the auth configuration -------------------------------------------
    '
    ' Without this, the first evidence that a group strategy is wrong is a
    ' dashboard refusing everyone while the log shows successful logins
    ' (finding G5-4). It prints what it resolved and never a password.
    if verb = "auth" then
        sub = ""
        if count(rest) > 0 then
            sub = rest[0]
        end if
        if sub != "check" then
            print to error "usage: gdash --root <dir> auth check [username]"
            exit(2)
        end if
        cfg = gdash_authcfg.load_config(p)
        if not cfg.ok then
            print to error "the auth configuration is not usable:"
            j = 0
            while j < count(cfg.errors)
                print to error "error: " + cfg.errors[j]
                j += 1
            end while
            print to error "local accounts still work; the directory is not consulted until this is fixed"
            exit(1)
        end if
        if not gdash_authcfg.has_directory(cfg.config) then
            print("auth: local accounts only (no directory configured in " + gdash_paths.auth_file(p) + ")")
            exit(0)
        end if
        d = cfg.config["directory"]
        print("auth: local accounts, then " + string(default(d["name"], "directory")) + " (" + string(d["host"]) + ", " + string(d["security"]) + ")")
        if count(rest) < 2 then
            print("give a username to test the directory end to end: gdash auth check <username>")
            exit(0)
        end if
        who = rest[1]
        ' A local account of the same name would shadow the directory, and an
        ' operator checking the directory deserves to be told rather than left
        ' wondering why their change had no effect.
        loaded_users = gdash_users.load_users(p)
        if loaded_users.ok and not is_unknown(gdash_users.lookup(loaded_users.db, who)) then
            print("NOTE: '" + who + "' is also a LOCAL account, and local is consulted first, so the directory below is not what signs them in")
        end if
        told = gdash_auth_ldap.explain(gdash_auth_ldap.directory_ctx(d, gdash_auth_ldap.live_directory()), who)
        j = 0
        while j < count(told.steps)
            print("  " + told.steps[j])
            j += 1
        end while
        if not told.ok then
            exit(1)
        end if
        print("  dn: " + told.dn)
        print("  email: " + told.email)
        print("  raw group values: " + join(told.raw, " | "))
        print("  groups gdash would use: " + join(told.groups, ", "))
        if count(told.groups) = 0 then
            print to error "no groups resolved: every dashboard gated on a group would refuse this user"
            exit(1)
        end if
        admin_now = gdash_auth_ldap.is_admin(d, told.groups)
        if admin_now then
            print("  and this user is a gdash administrator (admin_groups)")
        end if
        exit(0)
    end if

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
        ' ALL of them, grouped by what somebody is trying to do. The old text
        ' named five verbs of eight and left out every one a person needs to
        ' give themselves a login -- so the first thing a new operator had to
        ' do was the one thing the help did not mention.
        print to error "usage: gdash [--root <dir>] <command> [...]"
        print to error ""
        print to error "  dashboards"
        print to error "    list                                  what dashboards exist, and how fresh"
        print to error "    validate  <dashboard>                 check a record without running it"
        print to error "    refresh   <dashboard> [dataset] [--draft]   pull data now"
        print to error "    schedule                              one refresh pass over every published dashboard"
        print to error ""
        print to error "  versions"
        print to error "    publish   <dashboard>                 make the draft the version people see"
        print to error "    snapshots <dashboard>                 list published versions"
        print to error "    rollback  <dashboard> [snapshot]      go back to one"
        print to error "    diff      <dashboard> [from] [to]     what changed between two"
        print to error ""
        print to error "  people"
        print to error "    user list"
        print to error "    user add    <name> [--admin] [--email E] [--groups a,b]"
        print to error "    user passwd <name>                    password is read from stdin, never argv"
        print to error "    user groups <name> a,b"
        print to error "    user disable|enable|remove <name>"
        print to error ""
        print to error "  checking a configuration before it fails at 3am"
        print to error "    source check [profile]                connect, and say what answered"
        print to error "    auth   check [username]               the same for the directory"
        print to error ""
        print to error "  --root <dir> runs against a directory tree instead of the installed"
        print to error "  FHS paths; it is how gdash is developed and tested."
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
        print("schedule: " + string(result.checked) + " checked, " + string(result.refreshed) + " refreshed, " + string(result.unchanged) + " unchanged, " + string(result.failed) + " failed, " + string(result.swept) + " sessions swept")
        if result.failed > 0 then
            exit(1)
        end if
        exit(0)
    end if

    ' --- what is here ------------------------------------------------------
    '
    ' gdash had no way to answer "what dashboards do I have?". Every other verb
    ' takes a name, the server's root page said "open /d/<dashboard>" without
    ' saying which, and the only way to find out was to list a directory --
    ' which means knowing where the state directory is, which is the thing the
    ' resolver exists to stop people needing to know.
    if verb = "list" then
        names = gdash_refresh.dashboards(p)
        if count(names) = 0 then
            print("no dashboards in " + gdash_paths.dashboards_dir(p))
            print("a dashboard is a directory there with a draft.json in it")
            exit(0)
        end if
        k = 0
        while k < count(names)
            nm = names[k]
            pub = gdash_paths.publication(p, nm)
            state = "draft only"
            if pub.published then
                state = "published " + pub.snapshot
            end if
            loaded = gdash_record.load_file(pub.record_file)
            if not loaded.ok then
                ' A record that does not load is the most important thing on
                ' this list, so it says so instead of being skipped.
                print(nm + "  " + state + "  -- DOES NOT VALIDATE: " + join(loaded.errors, "; "))
            else
                dsn = keys(loaded.record["datasets"])
                ' The OLDEST dataset, not the newest: a dashboard is only as
                ' current as its stalest part, and a line reporting the
                ' freshest would be reassuring and wrong. Compared as epochs
                ' and formatted once at the end -- comparing the formatted
                ' strings happens to work while the format is ISO and stops
                ' working silently the day it is not.
                oldest_at = 0
                any_never = false
                m = 0
                while m < count(dsn)
                    st = gdash_sched.read_state(gdash_paths.dataset_state(p, nm, pub.mode, dsn[m]))
                    at = number(default(st.last_success, 0))
                    if at = 0 then
                        any_never = true
                    else if oldest_at = 0 or at < oldest_at then
                        oldest_at = at
                    end if
                    m += 1
                end while
                if count(dsn) = 0 then
                    oldest = "no datasets"
                else if any_never then
                    oldest = "never refreshed"
                else
                    oldest = "data as of " + gdash_format.when(oldest_at)
                end if
                print(nm + "  " + state + "  " + string(count(dsn)) + " dataset(s), " + oldest)
            end if
            k += 1
        end while
        exit(0)
    end if

    ' The verb is checked BEFORE the dashboard name is demanded. Every verb
    ' below takes a dashboard, so an unrecognised one used to be answered with
    ' "which dashboard?" -- which asks the reader for the wrong thing and does
    ' not mention that the word they typed is not a command.
    if not contains(["validate", "refresh", "publish", "rollback", "snapshots", "diff"], verb) then
        print to error "unknown command: " + verb
        print to error "known commands: list validate refresh schedule publish snapshots rollback diff user source auth"
        print to error "run gdash --help for what each one takes"
        exit(2)
    end if

    if count(rest) < 1 then
        print to error "which dashboard? -- " + verb + " takes the name of one"
        print to error "run gdash --help for what each command takes"
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

        ' PUBLISHED AND EMPTY IS A REAL STATE, AND IT USED TO BE A SILENT ONE.
        '
        ' Draft and published data never share a directory (design §7), so a
        ' dashboard whose draft is full of data is, the moment it is published,
        ' a dashboard with none -- every visual reads "No data yet" for every
        ' viewer until something refreshes the published copy. The natural
        ' first-run sequence is validate, refresh, publish, and it ends with a
        ' broken-looking dashboard.
        '
        ' Whether publish should CARRY the draft's data across is a design
        ' question and not the CLI's to answer: §7 authorises copying the
        ' record and is silent on the data. What the CLI can do is stop the
        ' state being a surprise, and name the one command that fixes it.
        pubmode = gdash_paths.publication(p, name)
        loaded_pub = gdash_record.load_file(pubmode.record_file)
        if loaded_pub.ok then
            dsn = keys(loaded_pub.record["datasets"])
            empty = 0
            m = 0
            while m < count(dsn)
                if not gdash_paths.path_exists(gdash_paths.dataset_db(p, name, "published", dsn[m])) then
                    empty += 1
                end if
                m += 1
            end while
            if empty > 0 then
                print("")
                print("note: the published copy has no data yet (" + string(empty) + " of " + string(count(dsn)) + " dataset(s)).")
                print("      published and draft data are kept apart, so publishing does not carry")
                print("      the draft's data across. Viewers will see \"No data yet\" until this runs:")
                print("")
                print("        gdash refresh " + name)
            end if
        end if
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
                ' NAME THE FILE. A record referring to a profile that is not
                ' configured is the first wall a new operator hits, and the
                ' message used to stop at "no profile named X" -- true, and no
                ' help at all to somebody who does not yet know that profiles
                ' live in a file, let alone which one.
                print to error "no connection profile named '" + string(ds["profile"]) + "'"
                print to error "  dataset '" + dn + "' of dashboard '" + name + "' asks for it"
                print to error "  profiles are defined in " + gdash_paths.connections_file(p)
                print to error "  `gdash source check` lists the ones that are"
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

    ' Naming the alternatives, because a bare refusal makes the reader go
    ' looking for a manual that does not exist yet.
    print to error "unknown command: " + verb
    print to error "known commands: list validate refresh schedule publish snapshots rollback diff user source auth"
    print to error "run gdash --help for what each one takes"
    exit(2)
end program
