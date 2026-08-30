' gdash — refresh state, and the decision to refresh.
'
' Two things live here because they are one thing: what we know about a
' dataset's last refresh, and whether that makes it due now.
'
' The decision is a PURE FUNCTION and the clock is an argument. A hermetic
' suite may not wait five minutes to watch an interval elapse, and a test that
' sleeps to observe scheduling is testing `sleep`. Everything about time in
' this module is a number someone handed in.
'
' There is no server-side timer to hang any of this on (finding G2-1): the
' `server` block has one hook, `on drain`, and `main` must return for the
' event loop to run at all. So the loop lives in gdash_scheduler.bas, a
' separate program, and this module is what it and the CLI both call.

library gdash_sched

    load crypto
    load gdash_paths from "gdash_paths.bas"

    function state_defaults()
        return { format: 1, last_attempt: 0, last_success: 0, last_error: "", rows: 0, hash: "", requested: 0, definition: "" }
    end function

    function _num(v, fallback)
        if is_unknown(v) or is_nothing(v) then
            return fallback
        end if
        return v
    end function

    function _txt(v)
        if is_unknown(v) or is_nothing(v) then
            return ""
        end if
        return string(v)
    end function

    ' A missing or unreadable state file is not an error: it is a dataset that
    ' has never refreshed, which is exactly what the defaults describe.
    function read_state(path)
        d = state_defaults()
        if not gdash_paths.path_exists(path) then
            return d
        end if
        on error goto next
        f {file} = path
        txt = read(f)
        if error then
            return d
        end if
        parsed = try_decode(txt)
        if error or not parsed.ok then
            return d
        end if
        v = parsed.value
        return { format: 1, last_attempt: _num(v["last_attempt"], 0), last_success: _num(v["last_success"], 0), last_error: _txt(v["last_error"]), rows: _num(v["rows"], 0), hash: _txt(v["hash"]), requested: _num(v["requested"], 0), definition: _txt(v["definition"]) }
    end function

    ' tmp-then-rename, like every other JSON store gdash writes (design §6).
    function write_state(path, st)
        tmp = path + ".tmp"
        on error goto next
        f {file} = tmp
        write(f, encode(st))
        if error then
            return false
        end if
        atomic_replace(tmp, path)
        if error then
            return false
        end if
        return true
    end function

    ' `refresh` stays a STRING in the record and gains sibling keys, because
    ' format: 1 is a published contract and GDASH-1 documented it as a string.
    function policy_of(ds)
        v = ds["refresh"]
        if is_unknown(v) or is_nothing(v) then
            return "manual"
        end if
        return string(v)
    end function

    function every_of(ds)
        return _num(ds["every"], 0)
    end function

    function min_age_of(ds)
        return _num(ds["min_age"], 0)
    end function

    ' A failed attempt counts as an attempt: a source that is down retries on
    ' its own cadence rather than at whatever rate the scheduler happens to
    ' tick. Otherwise `every: 300` against a dead server becomes a request
    ' every fifteen seconds, which is the shape of an accidental flood.
    function _last_touch(st)
        if st.last_attempt > st.last_success then
            return st.last_attempt
        end if
        return st.last_success
    end function

    ' What produced the data now on disk: the fetch query and the profile it
    ' came from. A published record can be rolled back to a version whose
    ' dataset asks a different question, and then the file on disk is the
    ' answer to a question nobody is asking any more (GDASH-3 brief §2.3).
    function definition_of(ds)
        return crypto.sha256_hex(string(ds["profile"]) + chr(31) + string(ds["sql"]))
    end function

    ' True when there IS data and it predates the definition now in force. A
    ' dataset that has never refreshed is not stale, it is empty, and the page
    ' already says so.
    function definition_stale(ds, st)
        if st.last_success = 0 then
            return false
        end if
        if st.definition = "" then
            return false
        end if
        return st.definition != definition_of(ds)
    end function

    ' Returns { due, reason }. `trigger` is "manual" or "policy".
    function due(ds, st, now, trigger)
        if trigger = "manual" then
            return { due: true, reason: "a person asked" }
        end if
        pol = policy_of(ds)
        if pol = "manual" then
            ' A manual dataset waiting for a person is the whole meaning of
            ' manual, stale definition or not. The page says the definition
            ' changed; it does not go behind the author's back.
            return { due: false, reason: "policy is manual" }
        end if
        ' A changed definition outranks an unelapsed interval: the data is not
        ' merely old, it answers the wrong question.
        if definition_stale(ds, st) then
            return { due: true, reason: "the dataset definition changed since this data was fetched" }
        end if
        if pol = "on_open" then
            if st.requested > 0 then
                return { due: true, reason: "a viewer opened the dashboard" }
            end if
            return { due: false, reason: "no open has requested it" }
        end if
        if pol = "interval" then
            touched = _last_touch(st)
            if touched = 0 then
                return { due: true, reason: "never refreshed" }
            end if
            ev = every_of(ds)
            if now - touched >= ev then
                return { due: true, reason: "interval of " + string(ev) + "s elapsed" }
            end if
            return { due: false, reason: "next in " + string(ev - (now - touched)) + "s" }
        end if
        return { due: false, reason: "unknown policy '" + pol + "'" }
    end function

    ' Page-open side of `on_open`. The request is a flag, not a queue: twenty
    ' people opening one dashboard file one request between them, which is why
    ' `min_age` needs no invented default -- omitting it means "on every open",
    ' and coalescing already bounds what that costs.
    function should_request(ds, st, now)
        if policy_of(ds) != "on_open" then
            return false
        end if
        if st.requested > 0 then
            return false
        end if
        age_floor = min_age_of(ds)
        if age_floor > 0 and st.last_success > 0 and now - st.last_success < age_floor then
            return false
        end if
        return true
    end function

    function with_request(st, now)
        return { format: 1, last_attempt: st.last_attempt, last_success: st.last_success, last_error: st.last_error, rows: st.rows, hash: st.hash, requested: now, definition: st.definition }
    end function

    ' A refresh that failed CLEARS the pending request rather than leaving it
    ' to be retried on every tick. The next page open files a new one, so the
    ' retry rate is bounded by people rather than by a constant this module
    ' would otherwise have to invent.
    function after_attempt(st, now, ok, message, rows, hash, definition)
        e = ""
        succeeded = st.last_success
        r = st.rows
        h = st.hash
        ' A failed attempt leaves the definition alone with the data it
        ' describes: what is on disk still came from the old query.
        d = st.definition
        if ok then
            succeeded = now
            r = rows
            h = hash
            d = definition
        else
            e = message
        end if
        return { format: 1, last_attempt: now, last_success: succeeded, last_error: e, rows: r, hash: h, requested: 0, definition: d }
    end function

end library
