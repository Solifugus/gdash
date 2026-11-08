' gdash — refresh supervision.
'
' Parent side of design §3. Writes a 0600 job file, starts the child, and on
' success swaps the staging table in for the live one and bumps the version.
'
' Stale-but-coherent beats broken: on any failure -- bad credentials, a source
' that is down, a hung child, a money value its column cannot hold -- the old
' dataset is left exactly as it was and the UI keeps showing "data as of".
' Nothing half-written is ever visible, because the only thing that makes new
' data visible is one transaction (gdash_store.swap).
'
' Two callers reach this: a person (the CLI, or the refresh button) and the
' scheduler. They differ in one word -- `trigger` -- and that word decides
' whether a draft dataset may refresh at all (design §3: draft datasets
' refresh manually only) and whether an unelapsed policy stands in the way.

library gdash_refresh

    load gdash_paths from "gdash_paths.bas"
    load gdash_store from "gdash_store.bas"
    load gdash_sched from "gdash_sched.bas"
    load gdash_audit from "gdash_audit.bas"
    load gdash_session from "gdash_session.bas"
    load gdash_session_files from "gdash_session_files.bas"
    load gdash_throttle from "gdash_throttle.bas"
    load gdash_record from "gdash_record.bas"
    load gdash_limits from "gdash_limits.bas"

    ' `process.self()` reports the ABSOLUTE path of the running interpreter and
    ' script, however the process was invoked. That is what makes both of these
    ' independent of the working directory.
    function _interpreter()
        got = env("GDASH_GBASIC")
        if not is_unknown(got) and string(got) != "" then
            return string(got)
        end if
        return process.self().interpreter
    end function

    ' The child lives beside whatever program is running -- gdash_cli.bas or
    ' gdash_server.bas, both of which sit next to it.
    '
    ' THIS USED TO BE "src/gdash_refresh_child.bas", RELATIVE TO THE WORKING
    ' DIRECTORY, so gdash could only refresh when started from the repository
    ' root (finding G8-2). Installed anywhere, or started by a service manager
    ' with any other working directory, every refresh failed with
    ' "src/gdash_refresh_child.bas: No such file or directory". It was
    ' invisible for eight phases because every process gdash starts is started
    ' from the repo root -- exactly how G6-8 hid.
    '
    ' GDASH_SRC still overrides, which is how the test suite points at src/
    ' while running a program out of tests/.
    function _child_script()
        got = env("GDASH_SRC")
        if not is_unknown(got) and string(got) != "" then
            return string(got) + "/gdash_refresh_child.bas"
        end if
        return gdash_paths.dir_of(process.self().script) + "/gdash_refresh_child.bas"
    end function

    ' A crashed child leaves its staging table behind. Residue is swept rather
    ' than trusted -- a half-written table is not data -- and the sweep says so
    ' in the audit log, because a sweep that deletes data silently is
    ' indistinguishable from data loss when someone comes looking.
    function sweep_staging(p, dashboard, mode, rec)
        removed = []
        db = gdash_paths.stage_db(p, dashboard, mode)
        names = keys(rec["datasets"])
        i = 0
        while i < count(names)
            if gdash_store.has_staging(db, names[i]) then
                if gdash_store.discard_staging(db, names[i]) then
                    removed = concat(removed, [names[i]])
                    logged = gdash_audit.event(p, "sweep.staging", { dashboard: dashboard, mode: mode, dataset: names[i] })
                end if
            end if
            i += 1
        end while
        return removed
    end function

    function _parse_child(text)
        out = { rows: 0, hash: "" }
        lines = split(string(text), chr(10))
        i = 0
        while i < count(lines)
            ln = trim(lines[i])
            if starts_with(ln, "rows=") then
                out.rows = default(number(mid(ln, 5, len(ln) - 5)), 0)
            else if starts_with(ln, "hash=") then
                out.hash = mid(ln, 5, len(ln) - 5)
            end if
            i += 1
        end while
        return out
    end function

    function _fail(p, dashboard, mode, dataset, st, now, message, vfile, statepath)
        after = gdash_sched.after_attempt(st, now, false, message, 0, "", "")
        wrote = gdash_sched.write_state(statepath, after)
        logged = gdash_audit.event(p, "refresh.failed", { dashboard: dashboard, mode: mode, dataset: dataset, reason: message })
        return { ok: false, message: message, version: gdash_store.read_version(vfile), rows: 0, unchanged: false, skipped: false }
    end function

    ' The lock is held around this. Everything it touches is one dataset's.
    '
    ' THE LIMITS COME FIRST (GDASH-16), and in this order: a root over its
    ' disk quota is refused, because more data is exactly what it cannot
    ' take; then a refresh slot is taken, from the server's set and this
    ' root's, WITHOUT WAITING -- with none free the refresh is DEFERRED, not
    ' failed, because nothing is wrong with it and the next pass will run it.
    ' A deferral writes no state, so it neither backs the dataset off nor
    ' says it failed.
    function _fetch_and_swap(p, dashboard, mode, rec, dataset, profile, st, now, lim)
        vfile = gdash_paths.version_file(p, dashboard, mode)
        statepath = gdash_paths.dataset_state(p, dashboard, mode, dataset)
        quota = gdash_limits.disk_check(p, lim)
        if not quota.ok then
            return _fail(p, dashboard, mode, dataset, st, now, quota.message, vfile, statepath)
        end if
        slots = gdash_limits.take_slots(p, lim)
        if not slots.ok and not slots.deferred then
            return _fail(p, dashboard, mode, dataset, st, now, slots.message, vfile, statepath)
        end if
        if not slots.ok then
            logged = gdash_audit.event(p, "refresh.deferred", { dashboard: dashboard, mode: mode, dataset: dataset, reason: slots.message })
            return { ok: true, message: slots.message, version: gdash_store.read_version(vfile), rows: st.rows, unchanged: true, skipped: true, deferred: true }
        end if
        outcome = _child_and_swap(p, dashboard, mode, rec, dataset, profile, st, now, lim)
        released = gdash_limits.release_slots(slots.held)
        return outcome
    end function

    function _child_and_swap(p, dashboard, mode, rec, dataset, profile, st, now, lim)
        ds = rec["datasets"][dataset]
        db = gdash_paths.stage_db(p, dashboard, mode)
        vfile = gdash_paths.version_file(p, dashboard, mode)
        statepath = gdash_paths.dataset_state(p, dashboard, mode, dataset)

        ' A stale staging table from an earlier crash must not be mistaken for
        ' this run's output.
        if not gdash_store.discard_staging(db, dataset) then
            return _fail(p, dashboard, mode, dataset, st, now, "cannot clear a stale staging table", vfile, statepath)
        end if

        job = { sql: ds["sql"], table: dataset, db: db, profile: profile, columns: ds["columns"], max_cells: lim.max_cells }
        token = dashboard + "-" + mode + "-" + dataset
        jobpath = gdash_paths.job_file(p, token)

        on error goto next
        jf {file} = jobpath
        write(jf, encode(job))
        if error then
            return _fail(p, dashboard, mode, dataset, st, now, "cannot write job file", vfile, statepath)
        end if
        ' The job file carries credentials and is written under run_dir, which
        ' is itself restricted at startup, so it is never world-readable in a
        ' directory anyone can traverse.
        locked = gdash_paths.restrict(jobpath)

        h = process.start({ command: _interpreter(), args: [_child_script(), jobpath] })
        if error then
            return _fail(p, dashboard, mode, dataset, st, now, "cannot start refresh child: " + error.message, vfile, statepath)
        end if

        ' Bound the run. The polite form first; force_after escalates only if
        ' the grace period expires.
        result = process.wait(h)
        if error then
            stopped = process.stop(h, { force_after: 5 })
            return _fail(p, dashboard, mode, dataset, st, now, "refresh child did not complete", vfile, statepath)
        end if

        out = process.read(h)
        released = process.release(h)

        ' The job file carries credentials; it does not outlive the fetch.
        on error goto next
        delete(jf)

        if not result.success then
            detail = ""
            if not is_unknown(out) then
                detail = trim(string(out.stderr))
            end if
            ' The live table is untouched: stale-but-coherent.
            cleared = gdash_store.discard_staging(db, dataset)
            return _fail(p, dashboard, mode, dataset, st, now, "refresh failed: " + detail, vfile, statepath)
        end if

        if not gdash_store.has_staging(db, dataset) then
            return _fail(p, dashboard, mode, dataset, st, now, "refresh child wrote no staging table", vfile, statepath)
        end if

        said = { rows: 0, hash: "" }
        if not is_unknown(out) then
            said = _parse_child(out.stdout)
        end if

        ' An unchanged refresh does not bump the version. Every open tab
        ' reloads on a bump, so a five-minute interval over data that has not
        ' moved would otherwise reload every viewer twelve times an hour to
        ' show them the same numbers.
        if said.hash != "" and said.hash = st.hash and gdash_store.has_dataset(db, dataset) then
            cleared = gdash_store.discard_staging(db, dataset)
            after = gdash_sched.after_attempt(st, now, true, "", said.rows, said.hash, gdash_sched.definition_of(ds))
            wrote = gdash_sched.write_state(statepath, after)
            logged = gdash_audit.event(p, "refresh.unchanged", { dashboard: dashboard, mode: mode, dataset: dataset, rows: said.rows })
            return { ok: true, message: "", version: gdash_store.read_version(vfile), rows: said.rows, unchanged: true, skipped: false }
        end if

        ' The quota again, now the new data is on disk beside the old: a
        ' refresh that would take the root over is refused before it swaps,
        ' so the old dataset is still what is served.
        quota = gdash_limits.disk_check(p, lim)
        if not quota.ok then
            cleared = gdash_store.discard_staging(db, dataset)
            return _fail(p, dashboard, mode, dataset, st, now, quota.message, vfile, statepath)
        end if

        ' The swap is one transaction; the version file bumps AFTER, so a
        ' reader woken by the version change always finds complete data.
        sw = gdash_store.swap(db, dataset)
        if not sw.ok then
            cleared = gdash_store.discard_staging(db, dataset)
            return _fail(p, dashboard, mode, dataset, st, now, "swap failed: " + sw.message, vfile, statepath)
        end if
        v = gdash_store.bump_version(vfile, vfile + ".tmp")

        after = gdash_sched.after_attempt(st, now, true, "", said.rows, said.hash, gdash_sched.definition_of(ds))
        wrote = gdash_sched.write_state(statepath, after)
        logged = gdash_audit.event(p, "refresh.ok", { dashboard: dashboard, mode: mode, dataset: dataset, rows: said.rows, version: v })
        return { ok: true, message: "", version: v, rows: said.rows, unchanged: false, skipped: false }
    end function

    ' Returns { ok, message, version, rows, unchanged, skipped }.
    ' `trigger` is "manual" (a person asked) or "policy" (the scheduler).
    function run(p, dashboard, mode, rec, dataset, profile, trigger)
        ds = rec["datasets"][dataset]
        if is_unknown(ds) then
            return { ok: false, message: "no such dataset: " + dataset, version: 0, rows: 0, unchanged: false, skipped: false }
        end if

        ' Design §3, enforced at the entry point rather than by convention:
        ' draft datasets refresh manually only. An author's half-finished
        ' query must not be able to hammer a production source on a timer.
        if mode = "draft" and trigger != "manual" then
            return { ok: false, message: "dataset '" + dataset + "' is a draft; draft datasets refresh manually only", version: 0, rows: 0, unchanged: false, skipped: false }
        end if

        ' CHECKED, not assumed. This was `made = ensure_dir(...)` twice with the
        ' result dropped, and the install's own first-run sequence makes it
        ' fail: the message tells an administrator to run the CLI before the
        ' service exists, so `<cache>/<dashboard>/` ends up owned by root while
        ' `<cache>` is owned by the service user, and the service then cannot
        ' create `published/` inside it (G14-1).
        '
        ' The failure has to be a VALUE here. What happened instead was worse
        ' than an unhelpful message: the write below failed and left an error
        ' PENDING AND UNACKNOWLEDGED, and `with lock` raised into it and escaped
        ' the frame -- taking the whole scheduler pass with it.
        datadir = gdash_paths.data_dir(p, dashboard, mode)
        if not gdash_paths.ensure_dir(datadir) then
            return { ok: false, message: "cannot create the data directory " + datadir + " (check that the service user owns it and every directory above it)", version: 0, rows: 0, unchanged: false, skipped: false }
        end if
        if not gdash_paths.ensure_dir(p.run_dir) then
            return { ok: false, message: "cannot create the run directory " + p.run_dir, version: 0, rows: 0, unchanged: false, skipped: false }
        end if

        statepath = gdash_paths.dataset_state(p, dashboard, mode, dataset)
        lockpath = gdash_paths.dataset_lock(p, dashboard, mode, dataset)
        vfile = gdash_paths.version_file(p, dashboard, mode)

        on error goto next
        lf {file} = lockpath
        if not gdash_paths.path_exists(lockpath) then
            write(lf, "")
            ' CHECKED PROMPTLY. gBASIC holds one pending error at a time, and a
            ' raise arriving while one is unacknowledged escapes the frame --
            ' so this check is what keeps a lock that cannot be created from
            ' becoming a crash three lines later.
            if error then
                return { ok: false, message: "cannot create the dataset lock " + lockpath + " (check that the service user owns the directory)", version: 0, rows: 0, unchanged: false, skipped: false }
            end if
        end if

        lim = gdash_limits.for_root(p)
        if not lim.ok then
            return { ok: false, message: "this site's limits cannot be read, so nothing refreshes: " + lim.message, version: 0, rows: 0, unchanged: false, skipped: false }
        end if

        outcome = { ok: false, message: "could not take the dataset lock", version: 0, rows: 0, unchanged: false, skipped: false }

        ' The dataset lock WAITS -- the refresh slots in gdash_limits are the
        ' ones that do not -- so it serializes, and the RE-READ of the state
        ' after acquiring it is what removes the duplicate fetch -- which is
        ' the right place for it anyway, since it also covers two refreshers
        ' that never overlapped inside the lock at all.
        with lock(lf)
            st = gdash_sched.read_state(statepath)
            now = epoch()
            verdict = gdash_sched.due(ds, st, now, trigger)
            if not verdict.due then
                outcome = { ok: true, message: verdict.reason, version: gdash_store.read_version(vfile), rows: st.rows, unchanged: true, skipped: true }
            else
                outcome = _fetch_and_swap(p, dashboard, mode, rec, dataset, profile, st, now, lim)
            end if
        end with

        return outcome
    end function

    ' Every dashboard the state directory knows about, in a stable order so a
    ' pass does not depend on filesystem order (`list` returns whatever the
    ' filesystem gives).
    function dashboards(p)
        dir = gdash_paths.dashboards_dir(p)
        out = []
        on error goto next
        entries = folders(dir)
        if error then
            return out
        end if
        i = 0
        while i < count(entries)
            out = concat(out, [entries[i].name])
            i += 1
        end while
        return sort(out)
    end function

    ' One scheduling pass: every PUBLISHED dashboard, every dataset, refreshed
    ' if its policy says it is due. Draft dashboards are skipped entirely --
    ' not refused per dataset, skipped -- because a draft has no policy that
    ' can fire (design §3) and walking one would only produce noise.
    '
    ' Returns { checked, refreshed, unchanged, failed, deferred, notes }. It never
    ' raises: a scheduler that dies on one bad dashboard stops refreshing
    ' every good one.
    function pass(p)
        profiles = load_profiles(p)
        names = dashboards(p)
        checked = 0
        refreshed = 0
        unchanged = 0
        failed = 0
        deferred = 0
        notes = []
        i = 0
        while i < count(names)
            name = names[i]
            pub = gdash_paths.publication(p, name)
            if pub.published then
                loaded = gdash_record.load_file(pub.record_file)
                if not loaded.ok then
                    failed += 1
                    notes = concat(notes, [name + ": published record is invalid: " + join(loaded.errors, "; ")])
                    logged = gdash_audit.event(p, "schedule.invalid", { dashboard: name, reason: join(loaded.errors, "; ") })
                else
                    rec = loaded.record
                    swept = sweep_staging(p, name, "published", rec)
                    ds = keys(rec["datasets"])
                    j = 0
                    while j < count(ds)
                        checked += 1
                        prof = profiles[rec["datasets"][ds[j]]["profile"]]
                        if is_unknown(prof) then
                            failed += 1
                            notes = concat(notes, [name + "." + ds[j] + ": no connection profile named '" + string(rec["datasets"][ds[j]]["profile"]) + "'"])
                        else
                            ' GUARDED. `pass` counts failures, so it was built
                            ' to be resilient -- but a RAISE bypassed the
                            ' counting and killed the run, turning one
                            ' dashboard's misconfiguration into a total
                            ' scheduling outage (G14-2). A pass that gives up
                            ' on the third of nine dashboards is worse than one
                            ' that reports the third and does the other eight.
                            on error goto next
                            r = run(p, name, "published", rec, ds[j], prof, "policy")
                            if error then
                                r = { ok: false, message: "refresh raised: " + error.message, version: 0, rows: 0, unchanged: false, skipped: false }
                            end if
                            if not r.ok then
                                failed += 1
                                notes = concat(notes, [name + "." + ds[j] + ": " + r.message])
                            else if default(r["deferred"], false) then
                                deferred += 1
                                notes = append(notes, name + "." + ds[j] + ": " + r.message)
                            else if r.skipped then
                                unchanged += 0
                            else if r.unchanged then
                                unchanged += 1
                                notes = concat(notes, [name + "." + ds[j] + ": unchanged"])
                            else
                                refreshed += 1
                                notes = concat(notes, [name + "." + ds[j] + ": refreshed " + string(r.rows) + " rows -> version " + string(r.version)])
                            end if
                        end if
                        j += 1
                    end while
                end if
            end if
            i += 1
        end while
        ' EXPIRED SESSIONS, on the same pass. `gdash_session.sweep` has existed
        ' and been tested since GDASH-4 and was called by nothing through three
        ' phases; /run clearing on reboot bounds the mess without bounding it
        ' well, and a machine that stays up for a year accumulates a file per
        ' abandoned browser.
        '
        ' It belongs here for the same reason sweep_staging does: this is the
        ' periodic maintenance pass, not the refresh pass, and both callers of
        ' it get the sweep without either remembering to ask.
        swept = gdash_session.sweep(gdash_session_files.store(p), epoch(), gdash_session.limits())
        ' Forgotten sign-in counters go too. A guesser inventing usernames
        ' would otherwise leave one file per invented name.
        forgot = gdash_throttle.sweep_attempts(p, epoch(), gdash_throttle.throttle_limits())
        if forgot > 0 then
            notes = concat(notes, ["forgot " + string(forgot) + " sign-in counter(s)"])
        end if
        if swept > 0 then
            notes = concat(notes, ["swept " + string(swept) + " expired session(s)"])
        end if
        return { checked: checked, refreshed: refreshed, unchanged: unchanged, failed: failed, deferred: deferred, notes: notes, swept: swept }
    end function

    ' Connection profiles are server-level and never live in a record
    ' (design §2, §8).
    function load_profiles(p)
        path = gdash_paths.connections_file(p)
        on error goto next
        f {file} = path
        if error then
            return {}
        end if
        if not exists(f) then
            return {}
        end if
        parsed = try_decode(read(f))
        if error or not parsed.ok then
            return {}
        end if
        if type(parsed.value) != "record" then
            ' Connection profiles that are not an object are no profiles at
            ' all; every dataset then fails by name on its own profile, which
            ' is a better message than a raise.
            return {}
        end if
        return parsed.value
    end function

end library
