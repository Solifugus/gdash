' gdash — local accounts.
'
' /etc/gdash/users.json, mode 0600 (design §6). One record per username:
' password_hash, groups, admin, disabled.
'
' ONE hash field, because password_hash() embeds the algorithm, its parameters
' and the salt in the string it returns (finding G4-1). A separate `algorithm`
' column -- which the gbasic site's plan carries, and which design §8 implied
' by naming pbkdf2/scrypt -- would be a second source of truth about a fact the
' hash already states.
'
' No password ever enters argv, the environment, a log line, a record, an audit
' field or a test fixture. The CLI reads it from stdin.

library gdash_users

    load gdash_paths from "gdash_paths.bas"

    function empty()
        return { format: 1, users: {} }
    end function

    function load_users(p)
        path = gdash_paths.users_file(p)
        if not gdash_paths.path_exists(path) then
            return { ok: true, db: empty(), message: "" }
        end if
        on error goto next
        f {file} = path
        txt = read(f)
        if error then
            return { ok: false, db: empty(), message: "cannot read " + path }
        end if
        parsed = try_decode(txt)
        if error or not parsed.ok then
            ' A user file gdash cannot parse must not become a user file with
            ' no users in it: that would be a locked door quietly removed.
            return { ok: false, db: empty(), message: "users file is not valid JSON" }
        end if
        v = parsed.value
        if is_unknown(v["users"]) then
            return { ok: false, db: empty(), message: "users file has no 'users' object" }
        end if
        return { ok: true, db: v, message: "" }
    end function

    function save(p, db)
        made = gdash_paths.ensure_dir(p.config_dir)
        path = gdash_paths.users_file(p)
        tmp = path + ".tmp"
        on error goto next
        f {file} = tmp
        write(f, encode(db))
        if error then
            return false
        end if
        ' Restricted BEFORE it becomes the real file: a window in which the
        ' hashes are world-readable is a window.
        locked = gdash_paths.restrict(tmp)
        atomic_replace(tmp, path)
        if error then
            return false
        end if
        locked = gdash_paths.restrict(path)
        return true
    end function

    function lookup(db, username)
        if username = "" then
            return unknown
        end if
        return db["users"][username]
    end function

    function names(db)
        return sort(keys(db["users"]))
    end function

    ' Returns { ok, message }. The message is the SAME for an unknown user, a
    ' wrong password and a disabled account: naming which one failed is a
    ' user-enumeration oracle, and gdash is often on a network where knowing
    ' who has an account is itself worth something.
    function authenticate(db, username, password)
        u = lookup(db, username)
        if is_unknown(u) then
            ' Still spend a hash, so an unknown username does not answer
            ' faster than a wrong password.
            burned = password_verify(password, "$y$j9T$notarealsaltvalue$notarealhashvalueatallnotarealhashvalue")
            return { ok: false, message: "that username and password do not match", user: {} }
        end if
        if u["disabled"] = true then
            burned = password_verify(password, string(default(u["password_hash"], "x")))
            return { ok: false, message: "that username and password do not match", user: {} }
        end if
        on error goto next
        good = password_verify(password, string(u["password_hash"]))
        if error or not good then
            return { ok: false, message: "that username and password do not match", user: {} }
        end if
        return { ok: true, message: "", user: { name: username, groups: groups_of(u), admin: u["admin"] = true } }
    end function

    function groups_of(u)
        g = u["groups"]
        if is_unknown(g) then
            return []
        end if
        return g
    end function

    function upsert(db, username, password_hash, groups, admin, disabled)
        users = db["users"]
        existing = users[username]
        ph = password_hash
        if ph = "" and not is_unknown(existing) then
            ph = string(existing["password_hash"])
        end if
        users[username] = { password_hash: ph, groups: groups, admin: admin, disabled: disabled }
        return { format: 1, users: users }
    end function

    function drop_user(db, username)
        users = {}
        have = keys(db["users"])
        i = 0
        while i < count(have)
            if have[i] != username then
                users[have[i]] = db["users"][have[i]]
            end if
            i += 1
        end while
        return { format: 1, users: users }
    end function

    ' The identity a request carries once it is authenticated. `user_*` is
    ' built from this and from nothing the client sent (design §2).
    function identity(db, username)
        u = lookup(db, username)
        if is_unknown(u) then
            return unknown
        end if
        if u["disabled"] = true then
            return unknown
        end if
        return { name: username, groups: groups_of(u), admin: u["admin"] = true }
    end function

end library
