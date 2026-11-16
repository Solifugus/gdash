' gdash — a tenant, exported and imported (GDASH-17; gdash_saas_design.md §6).
'
' "Downtime is acceptable; data loss is not." Backup, moving a tenant between
' servers and deleting one are the same directory operation, so they are one
' module, exercised before they are needed rather than written during an
' outage.
'
' AN EXPORT IS A DIRECTORY, not an archive. `zip.write` builds an archive from
' members held in memory and refuses anything past 4 GB, and a tenant's quota
' may be larger than either allows (GDASH-17 step 0). A directory is what
' `tar`, `rsync` and `scp` already move.
'
'   <dest>/manifest.json   written LAST: an export without one is unfinished
'   <dest>/root/etc/ ...   the tenant's own files, run/ excepted
'
' IT RUNS LIVE, in an order that keeps it whole:
'   - every `current` pointer FIRST. Snapshots are never deleted and a pointer
'     is renamed into place only after its snapshot is written, so a pointer
'     copied first names a snapshot the later walk will find;
'   - every other file, each of which gdash writes to a temporary and renames,
'     or appends to (the audit log, whose copy is then a prefix of it);
'   - each dataset database by `gsql.backup`, a consistent copy as of now
'     made while it stays in use. Never its raw files, which an owner may be
'     writing.
' run/ is never exported: it holds sessions, counters and slots, all of which
' mean nothing after a move.
'
' AN EXPORT HOLDS THE TENANT'S CREDENTIALS (connections.json, models.json,
' users.json, the CSRF secret), so it is 0700 and every file in it 0600.
'
' AN IMPORT CHECKS EVERYTHING BEFORE IT WRITES ANYTHING: the manifest's format,
' every path, every file's size and SHA-256, and that nothing is there the
' manifest does not name. It copies into a hidden directory beside the target,
' renames that into place, rewrites the stamp for THIS server's registry, and
' writes the registry entry LAST -- the order `tenant create` uses, so a
' tenant half-imported is unreachable rather than half-open.

library gdash_export

    load gdash_paths from "gdash_paths.bas"
    load gdash_tenants from "gdash_tenants.bas"
    load gdash_store from "gdash_store.bas"

    ' The formats this build reads: an export's own, and a tenant stamp's.
    function export_format()
        return 1
    end function

    function stamp_format()
        return gdash_tenants.current_format()
    end function

    function _chunk()
        return 4194304
    end function

    ' Every file under `dir`, as paths relative to it, depth first.
    function _walk(dir, rel)
        out = []
        on error goto next
        entries = list(dir)
        if error then
            return out
        end if
        on error stop
        for each e in entries
            r = e.name
            if rel != "" then
                r = rel + "/" + e.name
            end if
            if e.type = "folder" then
                for each f in _walk(e.path, r)
                    out = append(out, f)
                next
            else
                out = append(out, r)
            end if
        next
        return out
    end function

    ' A file's size and SHA-256, read a chunk at a time so a large audit log
    ' or dataset is never held whole. { ok, size, sha256, message }.
    function _digest(path)
        on error goto next
        f {file} = path
        size = bytes(f)
        if error then
            return { ok: false, size: 0, sha256: "", message: "cannot read " + path }
        end if
        h = hash_start("sha256")
        at = 0
        while at < size
            piece = read_at(f, at, _chunk())
            if error then
                return { ok: false, size: 0, sha256: "", message: "cannot read " + path }
            end if
            if byte_count(piece) = 0 then
                break
            end if
            h = hash_update(h, piece)
            at += byte_count(piece)
        end while
        return { ok: true, size: size, sha256: hex_encode(hash_finish(h)), message: "" }
    end function

    ' A copy, a chunk at a time, owner-only, with the digest of what was
    ' copied. { ok, size, sha256, message }.
    function _copy(src, dst)
        made = gdash_paths.ensure_dir(gdash_paths.dir_of(dst))
        on error goto next
        s {file} = src
        size = bytes(s)
        d {file} = dst
        write(d, "")
        chmod(d, "0600")
        if error then
            return { ok: false, size: 0, sha256: "", message: "cannot copy " + src + " to " + dst + ": " + error.message }
        end if
        h = hash_start("sha256")
        at = 0
        while at < size
            piece = read_at(s, at, _chunk())
            if error then
                return { ok: false, size: 0, sha256: "", message: "cannot read " + src + ": " + error.message }
            end if
            if byte_count(piece) = 0 then
                break
            end if
            append(d, piece)
            if error then
                return { ok: false, size: 0, sha256: "", message: "cannot write " + dst + ": " + error.message }
            end if
            h = hash_update(h, piece)
            at += byte_count(piece)
        end while
        return { ok: true, size: at, sha256: hex_encode(hash_finish(h)), message: "" }
    end function

    ' Make `dir` and everything under it owner-only: 0700 directories, 0600
    ' files. gsql.backup writes its files with the process's own umask.
    function _close_tree(dir)
        ok = gdash_paths.close_dir(dir)
        on error goto next
        entries = list(dir)
        if error then
            return ok
        end if
        on error stop
        for each e in entries
            if e.type = "folder" then
                ok = _close_tree(e.path) and ok
            else
                on error goto next
                f {file} = e.path
                chmod(f, "0600")
                if error then
                    ok = false
                end if
                on error stop
            end if
        next
        return ok
    end function

    function _empty_or_absent(dir)
        if not gdash_paths.path_exists(dir) then
            return true
        end if
        on error goto next
        entries = list(dir)
        if error then
            return false
        end if
        return count(entries) = 0
    end function

    function _utc_now()
        return string(now()) + "Z"
    end function

    ' --- export -------------------------------------------------------------
    '
    ' { ok, tenant, files, bytes, datasets, message }. `with_data` false leaves
    ' the datasets to refetch, which is what a single root's backup does.
    function export_tenant(base_p, id, dest, with_data)
        out = { ok: false, tenant: string(id), files: 0, bytes: 0, datasets: 0, message: "" }
        tr = gdash_tenants.roles_for(base_p, id)
        if not tr.ok then
            out.message = tr.message
            return out
        end if
        loaded = gdash_tenants.load_registry(base_p)
        entry = loaded.registry["tenants"][id]
        tp = tr.p
        if not _empty_or_absent(dest) then
            out.message = dest + " already holds something; an export goes into a new or empty directory"
            return out
        end if
        if not gdash_paths.ensure_dir(dest) or not gdash_paths.close_dir(dest) then
            out.message = "cannot create " + dest
            return out
        end if
        stamp = _read_json(gdash_paths.tenant_stamp(tp))
        if not stamp.ok then
            out.message = "tenant '" + id + "' has no readable format stamp (" + gdash_paths.tenant_stamp(tp) + ")"
            return out
        end if

        files = []
        done = {}
        ' The pointers first: see the header.
        for each d in _walk(gdash_paths.dashboards_dir(tp), "")
            if ends_with(d, "/current") then
                rel = "lib/dashboards/" + d
                c = _copy(tp.state_dir + "/dashboards/" + d, dest + "/root/" + rel)
                if not c.ok then
                    out.message = c.message
                    return out
                end if
                files = append(files, { path: rel, size: c.size, sha256: c.sha256 })
                done[rel] = true
            end if
        next
        for each role in [{ name: "etc", dir: tp.config_dir }, { name: "lib", dir: tp.state_dir }, { name: "log", dir: tp.log_dir }]
            for each f in _walk(role.dir, "")
                rel = role.name + "/" + f
                if is_unknown(done[rel]) and not ends_with(f, ".tmp") then
                    c = _copy(role.dir + "/" + f, dest + "/root/" + rel)
                    if not c.ok then
                        out.message = c.message
                        return out
                    end if
                    files = append(files, { path: rel, size: c.size, sha256: c.sha256 })
                end if
            next
        next

        ' The datasets: each database by backup, and beside it the version
        ' and dataset states that describe it. Locks and temporaries are
        ' about processes on this server, not about the data.
        datasets = 0
        if with_data then
            on error goto next
            dashes = list(tp.cache_dir)
            if error then
                dashes = []
            end if
            on error stop
            for each dsh in dashes
                if dsh.type = "folder" then
                    for each mode in ["draft", "published"]
                        ddir = gdash_paths.data_dir(tp, dsh.name, mode)
                        db = gdash_paths.stage_db(tp, dsh.name, mode)
                        rdir = "cache/" + dsh.name + "/" + mode
                        if gdash_paths.path_exists(db) then
                            b = gdash_store.backup(db, dest + "/root/" + rdir + "/data.gsql")
                            if not b.ok then
                                out.message = b.message
                                return out
                            end if
                            for each f in _walk(dest + "/root/" + rdir + "/data.gsql", "")
                                dg = _digest(dest + "/root/" + rdir + "/data.gsql/" + f)
                                if not dg.ok then
                                    out.message = dg.message
                                    return out
                                end if
                                files = append(files, { path: rdir + "/data.gsql/" + f, size: dg.size, sha256: dg.sha256 })
                            next
                            datasets += 1
                        end if
                        on error goto next
                        beside = list(ddir)
                        if error then
                            beside = []
                        end if
                        on error stop
                        for each e in beside
                            if e.type = "file" and not ends_with(e.name, ".lock") and not ends_with(e.name, ".tmp") then
                                c = _copy(e.path, dest + "/root/" + rdir + "/" + e.name)
                                if not c.ok then
                                    out.message = c.message
                                    return out
                                end if
                                files = append(files, { path: rdir + "/" + e.name, size: c.size, sha256: c.sha256 })
                            end if
                        next
                    next
                end if
            next
        end if
        closed = _close_tree(dest)

        total = 0
        for each f in files
            total += f.size
        next
        ' The registry entry travels with the tenant, so an import keeps its
        ' hosts, status and limits without an operator retyping them. The
        ' base and root do not: they are this server's.
        manifest = { format: export_format(), kind: "gdash-tenant-export", tenant: id, made: _utc_now(),
                     stamp_format: stamp.value["format"], with_data: with_data, entry: entry, files: files }
        mpath = dest + "/manifest.json"
        on error goto next
        mf {file} = mpath + ".tmp"
        write(mf, encode(manifest))
        chmod(mf, "0600")
        atomic_replace(mpath + ".tmp", mpath)
        if error then
            out.message = "cannot write " + mpath + ": " + error.message
            return out
        end if
        on error stop
        out.ok = true
        out.files = count(files)
        out.bytes = total
        out.datasets = datasets
        return out
    end function

    function _read_json(path)
        if not gdash_paths.path_exists(path) then
            return { ok: false, value: unknown }
        end if
        on error goto next
        f {file} = path
        got = try_decode(read(f))
        if error or not got.ok then
            return { ok: false, value: unknown }
        end if
        return { ok: true, value: got.value }
    end function

    ' --- checking an export -------------------------------------------------
    '
    ' { ok, manifest, errors }. Every sentence is a reason not to import it.
    function _safe_rel(rel)
        r = string(rel)
        if r = "" or starts_with(r, "/") or contains(r, chr(92)) then
            return false
        end if
        for each part in split(r, "/")
            if part = "" or part = "." or part = ".." then
                return false
            end if
        next
        return contains(["etc", "lib", "log", "cache"], split(r, "/")[0])
    end function

    function check_export(src)
        errs = []
        m = _read_json(src + "/manifest.json")
        if not m.ok then
            return { ok: false, manifest: {}, errors: [src + " has no readable manifest.json; it is not a finished export"] }
        end if
        man = m.value
        if type(man) != "record" or man["kind"] != "gdash-tenant-export" then
            return { ok: false, manifest: {}, errors: [src + "/manifest.json is not a gdash tenant export"] }
        end if
        if type(man["format"]) != "number" or man["format"] > export_format() then
            errs = append(errs, "the export has format " + string(man["format"]) + "; this build reads format " + string(export_format()) + " and earlier")
        end if
        if type(man["stamp_format"]) != "number" or man["stamp_format"] > stamp_format() then
            errs = append(errs, "the tenant's stamp has format " + string(man["stamp_format"]) + ", newer than this build's " + string(stamp_format()) + "; upgrade gdash before importing it")
        end if
        if not gdash_tenants.valid_id(man["tenant"]) then
            errs = append(errs, "the export names tenant '" + string(man["tenant"]) + "', which is not a valid id")
        end if
        if type(man["files"]) != "array" then
            return { ok: false, manifest: man, errors: append(errs, "the manifest lists no files") }
        end if
        named = {}
        for each f in man["files"]
            if type(f) != "record" or not _safe_rel(f["path"]) then
                errs = append(errs, "the manifest names a path that is not inside a tenant: '" + string(default(f["path"], "")) + "'")
            else if not is_unknown(named[f["path"]]) then
                errs = append(errs, "the manifest names " + f["path"] + " twice")
            else
                named[f["path"]] = true
                dg = _digest(src + "/root/" + f["path"])
                if not dg.ok then
                    errs = append(errs, f["path"] + " is missing")
                else if dg.size != f["size"] or dg.sha256 != f["sha256"] then
                    errs = append(errs, f["path"] + " does not match the manifest (changed or damaged since the export)")
                end if
            end if
        next
        ' Nothing the manifest does not name: a file added to an export after
        ' it was made is not part of the tenant.
        for each f in _walk(src + "/root", "")
            if is_unknown(named[f]) then
                errs = append(errs, f + " is in the export but not in its manifest")
            end if
        next
        return { ok: count(errs) = 0, manifest: man, errors: errs }
    end function

    ' --- import -------------------------------------------------------------
    '
    ' { ok, tenant, root, message }. `as_id` "" keeps the exported id; `hosts`
    ' [] keeps the exported hosts.
    function import_tenant(base_p, src, as_id, hosts)
        out = { ok: false, tenant: "", root: "", message: "" }
        chk = check_export(src)
        if not chk.ok then
            out.message = "refused, nothing was written: " + join(chk.errors, "; ")
            return out
        end if
        man = chk.manifest
        id = string(as_id)
        if id = "" then
            id = string(man["tenant"])
        end if
        out.tenant = id
        entry = default(man["entry"], {})
        if type(entry) != "record" then
            entry = {}
        end if
        use_hosts = hosts
        if count(use_hosts) = 0 then
            use_hosts = default(entry["hosts"], [])
        end if
        norm = []
        for each h in use_hosts
            norm = append(norm, gdash_tenants.normal_host(h))
        next
        new_entry = { hosts: norm, status: string(default(entry["status"], "active")), format: man["stamp_format"] }
        if not is_unknown(entry["limits"]) then
            new_entry["limits"] = entry["limits"]
        end if
        pre = gdash_tenants.can_register(base_p, id, new_entry)
        if not pre.ok then
            out.message = "refused, nothing was written: " + pre.message
            return out
        end if
        root = pre.root
        out.root = root
        if gdash_paths.path_exists(root) then
            out.message = "refused, nothing was written: " + root + " already exists; move it aside or import --as another id"
            return out
        end if

        ' Into a hidden directory beside the target, then renamed into place:
        ' a failure part way leaves a directory no registry entry names.
        work = gdash_paths.dir_of(root) + "/." + id + ".importing"
        if gdash_paths.path_exists(work) then
            out.message = "refused, nothing was written: " + work + " is left from an earlier import that did not finish; remove it first"
            return out
        end if
        for each f in man["files"]
            c = _copy(src + "/root/" + f["path"], work + "/" + f["path"])
            why = c.message
            if c.ok and c.sha256 != f["sha256"] then
                why = f["path"] + " changed while it was copied"
            end if
            if why != "" then
                out.message = "the import stopped part way and registered nothing: " + why + "; " + work + " can be removed"
                return out
            end if
        next
        wp = gdash_paths.roles(work)
        for each d in [wp.config_dir, wp.state_dir, wp.cache_dir, wp.log_dir, wp.run_dir, gdash_paths.dashboards_dir(wp)]
            made = gdash_paths.ensure_dir(d)
        next
        closed = _close_tree(work)
        on error goto next
        move(work, root)
        if error then
            out.message = "cannot move the imported tenant into " + root + ": " + error.message + "; " + work + " can be removed"
            return out
        end if
        on error stop

        ' The stamp is this server's now: it names THIS registry, and the id
        ' the tenant was imported as.
        rp = gdash_paths.roles(root)
        st = gdash_tenants.write_stamp(base_p, rp, id, man["stamp_format"])
        if not st.ok then
            out.message = st.message + "; the tenant is at " + root + " and is not registered"
            return out
        end if
        reg = gdash_tenants.register(base_p, id, new_entry)
        if not reg.ok then
            out.message = reg.message + "; the tenant is at " + root + " and is not registered"
            return out
        end if
        out.ok = true
        return out
    end function

    ' --- delete, for good ---------------------------------------------------
    '
    ' The registry entry first, so the tenant is unreachable before any of it
    ' goes; then the directory. Refused unless `backup` is a whole export of
    ' THIS tenant: a deletion nobody can undo is made undoable by the one
    ' thing that can be checked here.
    function purge_tenant(base_p, id, backup)
        out = { ok: false, root: "", made: "", message: "" }
        chk = check_export(backup)
        if not chk.ok then
            out.message = "refused: " + backup + " is not a whole export (" + join(chk.errors, "; ") + ")"
            return out
        end if
        if chk.manifest["tenant"] != id then
            out.message = "refused: " + backup + " is an export of '" + string(chk.manifest["tenant"]) + "', not '" + string(id) + "'"
            return out
        end if
        gone = gdash_tenants.remove_tenant(base_p, id)
        if not gone.ok then
            out.message = gone.message
            return out
        end if
        out.root = gone.root
        out.made = string(chk.manifest["made"])
        if gone.root = "" or not gdash_paths.path_exists(gone.root) then
            out.ok = true
            return out
        end if
        on error goto next
        remove_tree(gone.root)
        if error then
            out.message = "tenant '" + id + "' is unregistered, but its directory could not be removed: " + error.message
            return out
        end if
        out.ok = true
        return out
    end function

end library
