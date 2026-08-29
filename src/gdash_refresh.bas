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

library gdash_refresh

    load gdash_paths from "gdash_paths.bas"
    load gdash_store from "gdash_store.bas"

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

    ' A failed run cleans up its own staging file. GDASH-2 owns the sweep for
    ' residue left by a CRASH; residue left by a failure this process actually
    ' observed is this process's to clear, or the next run inherits a
    ' half-written file it would have to distrust anyway.
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

    ' Returns { ok, message, version, rows }.
    function run(p, dashboard, rec, dataset, profile)
        ds = rec["datasets"][dataset]
        if is_unknown(ds) then
            return { ok: false, message: "no such dataset: " + dataset, version: 0 }
        end if

        made = gdash_paths.ensure_dir(gdash_paths.data_dir(p, dashboard))
        made = gdash_paths.ensure_dir(p.run_dir)

        staging = gdash_paths.dataset_staging(p, dashboard, dataset)
        live = gdash_paths.dataset_db(p, dashboard, dataset)
        vfile = gdash_paths.version_file(p, dashboard)

        ' A stale staging file from an earlier crash must not be mistaken for
        ' this run's output.
        if not _discard_staging(staging) then
            return { ok: false, message: "cannot clear stale staging file", version: 0 }
        end if

        job = { sql: ds["sql"], table: dataset, staging: staging, profile: profile, columns: ds["columns"] }
        token = dashboard + "-" + dataset
        jobpath = gdash_paths.job_file(p, token)

        on error goto next
        jf {file} = jobpath
        write(jf, encode(job))
        if error then
            return { ok: false, message: "cannot write job file", version: 0 }
        end if
        locked = _restrict(jobpath)

        h = process.start({ command: _interpreter(), args: [_child_script(), jobpath] })
        if error then
            return { ok: false, message: "cannot start refresh child: " + error.message, version: 0 }
        end if

        ' Bound the run. The polite form first; force_after escalates only if
        ' the grace period expires.
        st = process.wait(h)
        if error then
            stopped = process.stop(h, { force_after: 5 })
            return { ok: false, message: "refresh child did not complete", version: 0 }
        end if

        out = process.read(h)
        released = process.release(h)

        ' The job file carries credentials; it does not outlive the fetch.
        on error goto next
        delete(jf)

        if not st.success then
            detail = ""
            if not is_unknown(out) then
                detail = trim(string(out.stderr))
            end if
            ' The old dataset file is untouched: stale-but-coherent.
            cleared = _discard_staging(staging)
            return { ok: false, message: "refresh failed: " + detail, version: gdash_store.read_version(vfile) }
        end if

        if not gdash_paths.path_exists(staging) then
            return { ok: false, message: "refresh child wrote no staging file", version: gdash_store.read_version(vfile) }
        end if

        ' Swap is a single POSIX rename; the version file bumps AFTER, so a
        ' reader woken by the version change always finds complete data.
        sw = gdash_store.swap(staging, live)
        if not sw.ok then
            cleared = _discard_staging(staging)
            return { ok: false, message: "swap failed: " + sw.message, version: gdash_store.read_version(vfile) }
        end if
        v = gdash_store.bump_version(vfile, vfile + ".tmp")

        return { ok: true, message: "", version: v }
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
