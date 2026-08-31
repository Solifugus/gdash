' gdash — the file-backed session store.
'
' One small JSON file per session under <run_dir>/sessions/. Files rather than
' a database because workers share no in-memory state (design §5) and the
' filesystem is how every other global fact in gdash already travels; one file
' per session because that is a store with no shared writer and therefore no
' lock to take. /run is the FHS home for runtime state and is cleared on
' reboot, which is exactly a session's correct lifetime.
'
' These four functions are the storage half of the seam (G4-8). They are the
' whole of what a different backend would have to reimplement -- the gbasic
' site's Postgres tables would land here and nowhere else.
'
' The id is validated by gdash_session before it reaches any of these. They
' validate it again anyway: a store that trusts its keys is a store that can
' be walked out of, and this is the module where a bad key becomes a path.

library gdash_session_files

    load gdash_paths from "gdash_paths.bas"
    load gdash_session from "gdash_session.bas"

    function dir_for(p)
        return gdash_paths.session_dir(p)
    end function

    function _path(p, id)
        if not gdash_session.legal_id(id) then
            return ""
        end if
        return gdash_paths.session_file(p, id)
    end function

    function put(p, id, rec)
        path = _path(p, id)
        if path = "" then
            return false
        end if
        made = gdash_paths.ensure_dir(dir_for(p))
        tmp = path + ".tmp"
        on error goto next
        f {file} = tmp
        write(f, encode(rec))
        if error then
            return false
        end if
        atomic_replace(tmp, path)
        if error then
            return false
        end if
        return true
    end function

    ' `unknown` for a session that is not there -- and for one whose file is
    ' unreadable or corrupt, because a session gdash cannot read is a session
    ' gdash does not have.
    function get(p, id)
        path = _path(p, id)
        if path = "" then
            return unknown
        end if
        if not gdash_paths.path_exists(path) then
            return unknown
        end if
        on error goto next
        f {file} = path
        txt = read(f)
        if error then
            return unknown
        end if
        parsed = try_decode(txt)
        if error or not parsed.ok then
            return unknown
        end if
        return parsed.value
    end function

    function drop(p, id)
        path = _path(p, id)
        if path = "" then
            return false
        end if
        if not gdash_paths.path_exists(path) then
            return true
        end if
        on error goto next
        f {file} = path
        delete(f)
        if error then
            return false
        end if
        return true
    end function

    function ids(p)
        out = []
        dir = dir_for(p)
        on error goto next
        entries = files(dir)
        if error then
            return out
        end if
        i = 0
        while i < count(entries)
            nm = entries[i].name
            if ends_with(nm, ".json") then
                stem = mid(nm, 0, len(nm) - 5)
                if gdash_session.legal_id(stem) then
                    out = concat(out, [stem])
                end if
            end if
            i += 1
        end while
        return out
    end function

    ' The seam, assembled. A record of function values plus the context they
    ' need, because gBASIC has function references and not closures.
    function store(p)
        return { ctx: p, put: gdash_session_files.put, get: gdash_session_files.get, drop: gdash_session_files.drop, ids: gdash_session_files.ids }
    end function

end library
