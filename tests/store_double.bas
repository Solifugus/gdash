' A second, deliberately DIFFERENT session store, for the seam's tests.
'
' gdash ships one store: a file per session (gdash_session_files). This one
' keeps every session in a single JSON map. The shape is different on purpose
' -- one writer, one file, whole-map rewrite -- because a seam proved against
' a near-copy of its only implementation is not proved at all. The gbasic
' site's Postgres tables will be a third shape again.
'
' `ctx` is the path to the map file. gBASIC has function references and not
' closures, so the context travels as an argument rather than being captured.

library store_double

    function _read(path)
        on error goto next
        f {file} = path
        if not exists(f) then
            return {}
        end if
        txt = read(f)
        if error then
            return {}
        end if
        parsed = try_decode(txt)
        if error or not parsed.ok then
            return {}
        end if
        return parsed.value
    end function

    function _write(path, all)
        on error goto next
        f {file} = path
        write(f, encode(all))
        if error then
            return false
        end if
        return true
    end function

    function put(ctx, id, rec)
        all = _read(ctx)
        all[id] = rec
        return _write(ctx, all)
    end function

    function get(ctx, id)
        all = _read(ctx)
        return all[id]
    end function

    function drop(ctx, id)
        all = _read(ctx)
        out = {}
        have = keys(all)
        i = 0
        while i < count(have)
            if have[i] != id then
                out[have[i]] = all[have[i]]
            end if
            i += 1
        end while
        return _write(ctx, out)
    end function

    function ids(ctx)
        return keys(_read(ctx))
    end function

    function store(path)
        return { ctx: path, put: store_double.put, get: store_double.get, drop: store_double.drop, ids: store_double.ids }
    end function

end library
