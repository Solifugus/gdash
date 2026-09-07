' gdash — slowing down a password guesser.
'
' Deferred in GDASH-4 and again in GDASH-5, and it got worse in between: a
' directory now sits behind the login form, where a failed bind counts toward
' somebody else's lockout policy. A hash costs about 12ms, so an attacker who
' can reach the form can try on the order of eighty candidates a second per
' connection. This makes the eighty-first wait.
'
' THREE RULINGS SHAPE IT, and each is a decision rather than a default:
'
' 1. PER USERNAME, NOT PER ADDRESS. An intranet behind one NAT is one address,
'    and throttling an address throttles a floor. It also means an attacker
'    spreading guesses across many accounts is slowed on each of them, which is
'    the shape that actually matters here.
'
' 2. IT NEVER LOCKS. The delay grows and then stops growing. A permanent
'    lockout is a denial-of-service against a named colleague that anybody can
'    trigger by typing their name wrong, and gdash is an intranet product where
'    that name is easy to guess.
'
' 3. IT FORGETS. A counter with no expiry is a counter that eventually refuses
'    everybody. Silence for the forget window clears the record entirely.
'
' Workers share no in-memory state (design §5), so the counter is a file, like
' every other global fact in gdash.

library gdash_throttle

    load crypto
    load gdash_paths from "gdash_paths.bas"

    ' `grace` failures are free, then 1s doubling to a 30s ceiling, and the
    ' whole record is forgotten after fifteen quiet minutes.
    '
    ' THE GRACE IS THE POINT. A person who mistypes their password twice and
    ' gets it right on the third go should wait exactly as long as somebody who
    ' typed it right first time, which is not at all. Throttling from the first
    ' failure taxes the common case -- a typo -- to slow the rare one, and the
    ' rare one is barely slowed by the first second anyway. It is the eightieth
    ' guess that needs to be expensive, not the second.
    function throttle_limits()
        return { grace: 3, base: 1, cap: 30, forget: 900 }
    end function

    function no_attempts()
        return { failures: 0, last: 0 }
    end function

    ' The filename. A username is not a safe filename and a listing of /run
    ' should not enumerate accounts, so it is hashed -- which also gives every
    ' key the same length whatever an attacker sends.
    function key_for(username)
        return crypto.sha256_hex(lower(trim(string(username))))
    end function

    ' How long this name must wait before another attempt is worth making.
    ' Zero means now.
    function delay_remaining(state, now, lim)
        ' `grace` is a count of ATTEMPTS, so the comparison is `<`: with a
        ' grace of three, the check before the fourth attempt sees three
        ' failures and must refuse. Using `<=` here let a fourth attempt
        ' through, because the count is read before that attempt has failed --
        ' an off-by-one the end-to-end run caught by counting status codes.
        if state.failures < lim.grace then
            return 0
        end if
        if now - state.last >= lim.forget then
            return 0
        end if
        ' How many failures past the grace this is, counting from one.
        over = state.failures - lim.grace + 1
        wait = lim.base
        i = 1
        while i < over
            wait = wait * 2
            if wait >= lim.cap then
                wait = lim.cap
                i = over
            end if
            i += 1
        end while
        left = (state.last + wait) - now
        if left < 0 then
            return 0
        end if
        return left
    end function

    ' A failure moves the counter on -- unless the record has gone quiet long
    ' enough to be forgotten, in which case this is the first failure again.
    function after_failure(state, now, lim)
        n = state.failures + 1
        if now - state.last >= lim.forget then
            n = 1
        end if
        return { failures: n, last: now }
    end function

    ' --- the file half ----------------------------------------------------

    function read_attempts(p, key)
        path = gdash_paths.throttle_file(p, key)
        if not gdash_paths.path_exists(path) then
            return no_attempts()
        end if
        on error goto next
        f {file} = path
        txt = read(f)
        if error then
            return no_attempts()
        end if
        parsed = try_decode(txt)
        if error or not parsed.ok then
            return no_attempts()
        end if
        v = parsed.value
        if type(v) != "record" then
            return no_attempts()
        end if
        n = v["failures"]
        t = v["last"]
        if type(n) != "number" or type(t) != "number" then
            return no_attempts()
        end if
        return { failures: n, last: t }
    end function

    function write_attempts(p, key, state)
        made = gdash_paths.ensure_dir(gdash_paths.throttle_dir(p))
        path = gdash_paths.throttle_file(p, key)
        on error goto next
        tmp = path + ".tmp"
        f {file} = tmp
        write(f, encode({ format: 1, failures: state.failures, last: state.last }))
        if error then
            return false
        end if
        atomic_replace(tmp, path)
        if error then
            return false
        end if
        return true
    end function

    function clear_attempts(p, key)
        path = gdash_paths.throttle_file(p, key)
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

    ' Records past their forget window, on the maintenance pass. An attacker
    ' guessing at invented usernames would otherwise leave a file per guess.
    function sweep_attempts(p, now, lim)
        gone = 0
        dir = gdash_paths.throttle_dir(p)
        on error goto next
        entries = files(dir)
        if error then
            return 0
        end if
        i = 0
        while i < count(entries)
            nm = entries[i].name
            if ends_with(nm, ".json") then
                key = mid(nm, 0, len(nm) - 5)
                st = read_attempts(p, key)
                if st.failures <= 0 or now - st.last >= lim.forget then
                    if clear_attempts(p, key) then
                        gone += 1
                    end if
                end if
            end if
            i += 1
        end while
        return gone
    end function

end library
