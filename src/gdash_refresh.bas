' gdash — refresh supervision.
'
' Parent side of design §3. Writes a 0600 job file, starts the child, and on
' success renames the staging file over the live one and bumps the version.
'
' Stale-but-coherent beats broken: on any failure -- bad credentials, a source
' that is down, a hung child, a money value with too many decimals -- the old
' dataset file is left exactly as it was and the UI keeps showing "data as
' of". Nothing half-written is ever visible, because the only thing that makes
' new data visible is a single rename.
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
    load gdash_record from "gdash_record.bas"

    function _interpreter()
        return default(env("GDASH_GBASIC"), "gbasic")
    end function

    function _child_script()
        ' The child lives beside this module.
        return default(env("GDASH_SRC"), "src") + "/gdash_refresh_child.bas"
    end function

    ' No chmod builtin exists, so the mode is set by calling out. The job file
    ' is created and then restricted; it is written under run_dir, which is
    ' itself restricted at startup, so the file is never world-readable in a
    ' directory anyone can traverse.
    function _restrict(path)
        on error goto next
        r = process.run({ command: "chmod", args: ["600", path] })
        if error then
            return false
        end if
        return r.exit_code = 0
    end function

    function _discard_staging(staging)
        if not gdash_paths.path_exists(staging) then
            return true
        end if
        on error goto next
        sf {file} = staging
        delete(sf)
        if error then
            return false
        end if
        return true
    end function

    ' A crashed child leaves its staging file behind. Residue is swept rather
    ' than trusted -- a half-written file is not data -- and the sweep says so
    ' in the audit log, because a sweep that deletes files silently is
    ' indistinguishable from data loss when someone comes looking.
    function sweep_staging(p, dashboard, mode, rec)
        removed = []
        names = keys(rec["datasets"])
        i = 0
        while i < count(names)
            staging = gdash_paths.dataset_staging(p, dashboard, mode, names[i])
            if gdash_paths.path_exists(staging) then
                if _discard_staging(staging) then
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
        after = gdash_sched.after_attempt(st, now, false, message, 0, "")
        wrote = gdash_sched.write_state(statepath, after)
        logged = gdash_audit.event(p, "refresh.failed", { dashboard: dashboard, mode: mode, dataset: dataset, reason: message })
        return { ok: false, message: message, version: gdash_store.read_version(vfile), rows: 0, unchanged: false, skipped: false }
    end function

    ' The lock is held around this. Everything it touches is one dataset's.
    function _fetch_and_swap(p, dashboard, mode, rec, dataset, profile, st, now)
        ds = rec["datasets"][dataset]
        staging = gdash_paths.dataset_staging(p, dashboard, mode, dataset)
        live = gdash_paths.dataset_db(p, dashboard, mode, dataset)
        vfile = gdash_paths.version_file(p, dashboard, mode)
        statepath = gdash_paths.dataset_state(p, dashboard, mode, dataset)

        ' A stale staging file from an earlier crash must not be mistaken for
        ' this run's output.
        if not _discard_staging(staging) then
            return _fail(p, dashboard, mode, dataset, st, now, "cannot clear stale staging file", vfile, statepath)
        end if

        job = { sql: ds["sql"], table: dataset, staging: staging, profile: profile, columns: ds["columns"] }
        token = dashboard + "-" + mode + "-" + dataset
        jobpath = gdash_paths.job_file(p, token)

        on error goto next
        jf {file} = jobpath
        write(jf, encode(job))
        if error then
            return _fail(p, dashboard, mode, dataset, st, now, "cannot write job file", vfile, statepath)
        end if
        locked = _restrict(jobpath)

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
            ' The old dataset file is untouched: stale-but-coherent.
            cleared = _discard_staging(staging)
            return _fail(p, dashboard, mode, dataset, st, now, "refresh failed: " + detail, vfile, statepath)
        end if

        if not gdash_paths.path_exists(staging) then
            return _fail(p, dashboard, mode, dataset, st, now, "refresh child wrote no staging file", vfile, statepath)
        end if

        said = { rows: 0, hash: "" }
        if not is_unknown(out) then
            said = _parse_child(out.stdout)
        end if

        ' An unchanged refresh does not bump the version. Every open tab
        ' reloads on a bump, so a five-minute interval over data that has not
        ' moved would otherwise reload every viewer twelve times an hour to
        ' show them the same numbers.
        if said.hash != "" and said.hash = st.hash and gdash_paths.path_exists(live) then
            cleared = _discard_staging(staging)
            after = gdash_sched.after_attempt(st, now, true, "", said.rows, said.hash)
            wrote = gdash_sched.write_state(statepath, after)
            logged = gdash_audit.event(p, "refresh.unchanged", { dashboard: dashboard, mode: mode, dataset: dataset, rows: said.rows })
            return { ok: true, message: "", version: gdash_store.read_version(vfile), rows: said.rows, unchanged: true, skipped: false }
        end if

        ' Swap is a single POSIX rename; the version file bumps AFTER, so a
        ' reader woken by the version change always finds complete data.
        sw = gdash_store.swap(staging, live)
        if not sw.ok then
            cleared = _discard_staging(staging)
            return _fail(p, dashboard, mode, dataset, st, now, "swap failed: " + sw.message, vfile, statepath)
        end if
        v = gdash_store.bump_version(vfile, vfile + ".tmp")

        after = gdash_sched.after_attempt(st, now, true, "", said.rows, said.hash)
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

        made = gdash_paths.ensure_dir(gdash_paths.data_dir(p, dashboard, mode))
        made = gdash_paths.ensure_dir(p.run_dir)

        statepath = gdash_paths.dataset_state(p, dashboard, mode, dataset)
        lockpath = gdash_paths.dataset_lock(p, dashboard, mode, dataset)
        vfile = gdash_paths.version_file(p, dashboard, mode)

        on error goto next
        lf {file} = lockpath
        if not gdash_paths.path_exists(lockpath) then
            write(lf, "")
        end if

        outcome = { ok: false, message: "could not take the dataset lock", version: 0, rows: 0, unchanged: false, skipped: false }

        ' There is no non-blocking advisory lock (finding G2-6): lock(f) is
        ' flock(LOCK_EX). So the lock serializes, and the RE-READ of the state
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
                outcome = _fetch_and_swap(p, dashboard, mode, rec, dataset, profile, st, now)
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
    ' Returns { checked, refreshed, unchanged, failed, notes }. It never
    ' raises: a scheduler that dies on one bad dashboard stops refreshing
    ' every good one.
    function pass(p)
        profiles = load_profiles(p)
        names = dashboards(p)
        checked = 0
        refreshed = 0
        unchanged = 0
        failed = 0
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
                            r = run(p, name, "published", rec, ds[j], prof, "policy")
                            if not r.ok then
                                failed += 1
                                notes = concat(notes, [name + "." + ds[j] + ": " + r.message])
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
        return { checked: checked, refreshed: refreshed, unchanged: unchanged, failed: failed, notes: notes }
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
        return parsed.value
    end function

end library
