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

    ' One dataset's fetch into its staging table, and nothing else: no state
    ' is written and nothing is swapped, so a caller refreshing one dataset
    ' and a caller refreshing a whole dashboard (G57) decide those for
    ' themselves. { ok, message, rows, hash }; on failure the staging table
    ' is gone.
    function _stage(p, dashboard, mode, rec, dataset, profile, lim)
        ds = rec["datasets"][dataset]
        db = gdash_paths.stage_db(p, dashboard, mode)

        ' A stale staging table from an earlier crash must not be mistaken for
        ' this run's output.
        if not gdash_store.discard_staging(db, dataset) then
            return { ok: false, message: "cannot clear a stale staging table", rows: 0, hash: "" }
        end if

        job = { sql: ds["sql"], table: dataset, db: db, profile: profile, columns: ds["columns"], max_cells: lim.max_cells }
        token = dashboard + "-" + mode + "-" + dataset
        jobpath = gdash_paths.job_file(p, token)

        on error goto next
        jf {file} = jobpath
        write(jf, encode(job))
        if error then
            return { ok: false, message: "cannot write job file", rows: 0, hash: "" }
        end if
        ' The job file carries credentials and is written under run_dir, which
        ' is itself restricted at startup, so it is never world-readable in a
        ' directory anyone can traverse.
        locked = gdash_paths.restrict(jobpath)

        ' UNDER A MEMORY LIMIT (GDASH-16, gbasic B1), so a result too large
        ' for the machine kills the child that fetched it, not whatever the
        ' kernel's OOM killer would have chosen.
        memory = gdash_limits.child_memory(lim)
        h = process.start({ command: _interpreter(), args: [_child_script(), jobpath], limits: { memory: memory } })
        if error then
            return { ok: false, message: "cannot start refresh child: " + error.message, rows: 0, hash: "" }
        end if

        ' Bound the run. The polite form first; force_after escalates only if
        ' the grace period expires.
        result = process.wait(h)
        if error then
            stopped = process.stop(h, { force_after: 5 })
            return { ok: false, message: "refresh child did not complete", rows: 0, hash: "" }
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
            cleared = gdash_store.discard_staging(db, dataset)
            ' The kernel records no verdict, only evidence: a gBASIC child that
            ' fails an allocation dies by SIGABRT, and its peak says why.
            if default(result["signal"], 0) = 6 and not is_unknown(result["memory_limit"]) then
                return { ok: false, message: "the refresh ran out of its memory limit of " + gdash_limits.bytes_text(memory) + " (peak " + gdash_limits.bytes_text(default(result["peak_memory"], 0)) + "); the result is too large for this site -- narrow the query or aggregate it at the source", rows: 0, hash: "" }
            end if
            ' The live table is untouched: stale-but-coherent.
            return { ok: false, message: "refresh failed: " + detail, rows: 0, hash: "" }
        end if

        if not gdash_store.has_staging(db, dataset) then
            return { ok: false, message: "refresh child wrote no staging table", rows: 0, hash: "" }
        end if

        said = { rows: 0, hash: "" }
        if not is_unknown(out) then
            said = _parse_child(out.stdout)
        end if
        return { ok: true, message: "", rows: said.rows, hash: said.hash }
    end function

    ' An unchanged refresh does not bump the version. Every open tab reloads
    ' on a bump, so a five-minute interval over data that has not moved would
    ' otherwise reload every viewer twelve times an hour to show them the
    ' same numbers.
    function _unchanged(db, dataset, staged, st)
        return staged.hash != "" and staged.hash = st.hash and gdash_store.has_dataset(db, dataset)
    end function

    function _child_and_swap(p, dashboard, mode, rec, dataset, profile, st, now, lim)
        ds = rec["datasets"][dataset]
        db = gdash_paths.stage_db(p, dashboard, mode)
        vfile = gdash_paths.version_file(p, dashboard, mode)
        statepath = gdash_paths.dataset_state(p, dashboard, mode, dataset)

        staged = _stage(p, dashboard, mode, rec, dataset, profile, lim)
        if not staged.ok then
            return _fail(p, dashboard, mode, dataset, st, now, staged.message, vfile, statepath)
        end if

        if _unchanged(db, dataset, staged, st) then
            cleared = gdash_store.discard_staging(db, dataset)
            after = gdash_sched.after_attempt(st, now, true, "", staged.rows, staged.hash, gdash_sched.definition_of(ds))
            wrote = gdash_sched.write_state(statepath, after)
            logged = gdash_audit.event(p, "refresh.unchanged", { dashboard: dashboard, mode: mode, dataset: dataset, rows: staged.rows })
            return { ok: true, message: "", version: gdash_store.read_version(vfile), rows: staged.rows, unchanged: true, skipped: false }
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

        after = gdash_sched.after_attempt(st, now, true, "", staged.rows, staged.hash, gdash_sched.definition_of(ds))
        wrote = gdash_sched.write_state(statepath, after)
        logged = gdash_audit.event(p, "refresh.ok", { dashboard: dashboard, mode: mode, dataset: dataset, rows: staged.rows, version: v })
        return { ok: true, message: "", version: v, rows: staged.rows, unchanged: false, skipped: false }
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

    ' --- a dashboard refreshed as one (G57) -------------------------------------
    '
    ' Datasets refreshed one at a time put a dashboard, for as long as it takes
    ' to get through them, half on one extract and half on the last: the book
    ' measured revision 2's USD totals under revision 1's manifest. Every
    ' dataset of a dashboard is a table in ONE database (GDASH-20), so the cure
    ' is cheap: STAGE THEM ALL, THEN SWAP THEM ALL IN ONE TRANSACTION, with one
    ' version bump. A viewer sees the old dashboard or the new one.
    '
    ' AND IT IS ALL OR NOTHING. If one dataset fails to fetch, none is
    ' swapped: the dashboard stays coherent on its previous data, which is the
    ' stale-but-coherent rule (design §3) at the level a viewer reads it. Only
    ' the dataset that failed records a failure, so on a schedule it backs off
    ' and the next pass refreshes the others together without it.
    '
    ' Locks are taken in name order, so two whole-dashboard refreshes cannot
    ' each hold the lock the other waits for. One refresh slot covers the unit:
    ' its children run one after another.
    '
    ' Returns { ok, message, version, refreshed, unchanged, skipped, deferred,
    ' failed } -- the three lists name datasets; `failed` is the dataset that
    ' stopped the unit, or "".
    function run_together(p, dashboard, mode, rec, names, profiles, trigger)
        out = { ok: false, message: "", version: 0, refreshed: [], unchanged: [], skipped: [], deferred: false, failed: "", rows: {} }
        if mode = "draft" and trigger != "manual" then
            out.message = "dashboard '" + dashboard + "' is a draft; draft datasets refresh manually only"
            return out
        end if
        order = sort(names)
        for each dn in order
            if is_unknown(rec["datasets"][dn]) then
                out.message = "no such dataset: " + dn
                return out
            end if
            if is_unknown(profiles[rec["datasets"][dn]["profile"]]) then
                out.message = "no connection profile named '" + string(rec["datasets"][dn]["profile"]) + "' (dataset '" + dn + "'); profiles are defined in " + gdash_paths.connections_file(p)
                out.failed = dn
                return out
            end if
        next
        datadir = gdash_paths.data_dir(p, dashboard, mode)
        if not gdash_paths.ensure_dir(datadir) or not gdash_paths.ensure_dir(p.run_dir) then
            out.message = "cannot create the data directory " + datadir + " (check that the service user owns it and every directory above it)"
            return out
        end if
        lim = gdash_limits.for_root(p)
        if not lim.ok then
            out.message = "this site's limits cannot be read, so nothing refreshes: " + lim.message
            return out
        end if
        db = gdash_paths.stage_db(p, dashboard, mode)
        vfile = gdash_paths.version_file(p, dashboard, mode)

        held = []
        on error goto next
        for each dn in order
            lp = gdash_paths.dataset_lock(p, dashboard, mode, dn)
            lf {file} = lp
            if not exists(lf) then
                write(lf, "")
            end if
            if error then
                released = _unlock_all(held)
                out.message = "cannot create the dataset lock " + lp + " (check that the service user owns the directory)"
                return out
            end if
            got = lock(lf)
            held = append(held, lf)
        next
        on error stop
        out = _together_locked(p, dashboard, mode, rec, order, profiles, trigger, lim, db, vfile)
        released = _unlock_all(held)
        return out
    end function

    function _unlock_all(held)
        for each f in held
            on error goto next
            unlock(f)
            if error then
            end if
            on error stop
        next
        return true
    end function

    function _together_locked(p, dashboard, mode, rec, order, profiles, trigger, lim, db, vfile)
        out = { ok: false, message: "", version: gdash_store.read_version(vfile), refreshed: [], unchanged: [], skipped: [], deferred: false, failed: "", rows: {} }
        now = epoch()
        states = {}
        due = []
        ' Re-read inside the locks, as a single refresh does: a refresher that
        ' finished while this one waited has already done the work.
        for each dn in order
            st = gdash_sched.read_state(gdash_paths.dataset_state(p, dashboard, mode, dn))
            states[dn] = st
            if gdash_sched.due(rec["datasets"][dn], st, now, trigger).due then
                due = append(due, dn)
            else
                out.skipped = append(out.skipped, dn)
            end if
        next
        if count(due) = 0 then
            out.ok = true
            out.message = "nothing was due"
            return out
        end if

        quota = gdash_limits.disk_check(p, lim)
        if not quota.ok then
            for each dn in due
                f = _fail(p, dashboard, mode, dn, states[dn], now, quota.message, vfile, gdash_paths.dataset_state(p, dashboard, mode, dn))
            next
            out.message = quota.message
            return out
        end if
        slots = gdash_limits.take_slots(p, lim)
        if not slots.ok then
            if slots.deferred then
                logged = gdash_audit.event(p, "refresh.deferred", { dashboard: dashboard, mode: mode, datasets: due, reason: slots.message })
                out.ok = true
                out.deferred = true
                out.skipped = concat(out.skipped, due)
            else
                for each dn in due
                    f = _fail(p, dashboard, mode, dn, states[dn], now, slots.message, vfile, gdash_paths.dataset_state(p, dashboard, mode, dn))
                next
            end if
            out.message = slots.message
            return out
        end if
        out = _together_staged(p, dashboard, mode, rec, due, profiles, lim, db, vfile, states, now, out)
        released = gdash_limits.release_slots(slots.held)
        return out
    end function

    function _together_staged(p, dashboard, mode, rec, due, profiles, lim, db, vfile, states, now, out)
        staged = {}
        for each dn in due
            prof = profiles[rec["datasets"][dn]["profile"]]
            got = _stage(p, dashboard, mode, rec, dn, prof, lim)
            if not got.ok then
                ' NOTHING IS SWAPPED. The datasets already staged are discarded,
                ' and only the one that failed says so in its state.
                for each other in keys(staged)
                    cleared = gdash_store.discard_staging(db, other)
                next
                f = _fail(p, dashboard, mode, dn, states[dn], now, got.message, vfile, gdash_paths.dataset_state(p, dashboard, mode, dn))
                logged = gdash_audit.event(p, "refresh.unit_failed", { dashboard: dashboard, mode: mode, failed: dn, held_back: keys(staged) })
                out.failed = dn
                out.message = "dataset '" + dn + "' failed, so no dataset of '" + dashboard + "' was swapped and the dashboard still shows its previous data: " + got.message
                return out
            end if
            staged[dn] = got
            out.rows[dn] = got.rows
        next

        changed = []
        for each dn in due
            if _unchanged(db, dn, staged[dn], states[dn]) then
                cleared = gdash_store.discard_staging(db, dn)
                out.unchanged = append(out.unchanged, dn)
            else
                changed = append(changed, dn)
            end if
        next

        if count(changed) > 0 then
            quota = gdash_limits.disk_check(p, lim)
            if not quota.ok then
                for each dn in changed
                    cleared = gdash_store.discard_staging(db, dn)
                    f = _fail(p, dashboard, mode, dn, states[dn], now, quota.message, vfile, gdash_paths.dataset_state(p, dashboard, mode, dn))
                next
                out.unchanged = []
                out.message = quota.message
                return out
            end if
            sw = gdash_store.swap_all(db, changed)
            if not sw.ok then
                for each dn in changed
                    cleared = gdash_store.discard_staging(db, dn)
                    f = _fail(p, dashboard, mode, dn, states[dn], now, "swap failed: " + sw.message, vfile, gdash_paths.dataset_state(p, dashboard, mode, dn))
                next
                out.unchanged = []
                out.message = "swap failed: " + sw.message
                return out
            end if
            ' ONE bump for the unit, after the one commit: every open page
            ' reloads once, onto a dashboard that is all one extract.
            out.version = gdash_store.bump_version(vfile, vfile + ".tmp")
            out.refreshed = changed
        end if

        for each dn in due
            ds = rec["datasets"][dn]
            after = gdash_sched.after_attempt(states[dn], now, true, "", staged[dn].rows, staged[dn].hash, gdash_sched.definition_of(ds))
            wrote = gdash_sched.write_state(gdash_paths.dataset_state(p, dashboard, mode, dn), after)
        next
        logged = gdash_audit.event(p, "refresh.unit", { dashboard: dashboard, mode: mode, refreshed: changed, unchanged: out.unchanged, version: out.version })
        out.ok = true
        return out
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
                    ' THE DASHBOARD IS THE UNIT (G57): every dataset due on this
                    ' pass is staged and swapped together. One with no profile
                    ' cannot be fetched at all, so it is counted and left out
                    ' rather than holding the others back forever.
                    ds = sort(keys(rec["datasets"]))
                    unit = []
                    for each dn in ds
                        checked += 1
                        if is_unknown(profiles[rec["datasets"][dn]["profile"]]) then
                            failed += 1
                            notes = append(notes, name + "." + dn + ": no connection profile named '" + string(rec["datasets"][dn]["profile"]) + "'")
                        else
                            unit = append(unit, dn)
                        end if
                    next
                    if count(unit) > 0 then
                        ' GUARDED. `pass` counts failures, so it was built
                        ' to be resilient -- but a RAISE bypassed the
                        ' counting and killed the run, turning one
                        ' dashboard's misconfiguration into a total
                        ' scheduling outage (G14-2). A pass that gives up
                        ' on the third of nine dashboards is worse than one
                        ' that reports the third and does the other eight.
                        on error goto next
                        r = run_together(p, name, "published", rec, unit, profiles, "policy")
                        if error then
                            r = { ok: false, message: "refresh raised: " + error.message, version: 0, refreshed: [], unchanged: [], skipped: [], deferred: false, failed: "", rows: {} }
                        end if
                        on error stop
                        if not r.ok then
                            failed += 1
                            ' Named as dashboard.dataset when one dataset stopped
                            ' the unit, as a single failure always was.
                            who = name
                            if r.failed != "" then
                                who = name + "." + r.failed
                            end if
                            notes = append(notes, who + ": " + r.message)
                        else if r.deferred then
                            deferred += 1
                            notes = append(notes, name + ": " + r.message)
                        else
                            for each dn in r.unchanged
                                unchanged += 1
                                notes = append(notes, name + "." + dn + ": unchanged")
                            next
                            for each dn in r.refreshed
                                refreshed += 1
                                notes = append(notes, name + "." + dn + ": refreshed " + string(r.rows[dn]) + " rows -> version " + string(r.version))
                            next
                        end if
                    end if
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
