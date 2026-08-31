' gdash — server-side sessions, and the rules around them.
'
' THIS MODULE TOUCHES NO FILE. Everything that stores or retrieves anything
' arrives as a `store`: a record of function values plus the context they need.
' That is the storage seam the gbasic repo accepted for the eventual shared
' component (finding G4-8) -- gdash builds it first, against one real
' implementation, so extraction later is a move rather than a rewrite.
'
' The context rides in the record because gBASIC has function REFERENCES and
' not closures (`docs/first_class_functions_design.md` §2, deferred on
' purpose): a bare `gdash_session_files.put` cannot remember which root it
' belongs to, so the caller hands it over on every call. `ctx` is the caller's
' own resolved paths, not private wiring.
'
'   store = { ctx: <opaque>, put: fn(ctx, id, rec), get: fn(ctx, id),
'             drop: fn(ctx, id), ids: fn(ctx) }
'
' `get` returns `unknown` for a session that is not there. Nothing else in the
' interface may raise.

library gdash_session

    load crypto

    ' Absolute age caps a stolen cookie's usefulness; idle age caps an
    ' abandoned browser's. Both, because either alone leaves one of those open.
    function limits()
        return { absolute: 43200, idle: 3600, touch_after: 60 }
    end function

    ' A session id is a filename in the file-backed store, so it is validated
    ' as one -- here, once, rather than in the store, because a store that
    ' trusts its keys is a store that can be walked out of. base64url is
    ' letters, digits, '-' and '_': no '/', no '.', nothing to traverse with.
    function legal_id(id)
        if id = "" then
            return false
        end if
        if len(id) > 128 then
            return false
        end if
        i = 0
        while i < len(id)
            c = mid(id, i, 1)
            if not contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_", c) then
                return false
            end if
            i += 1
        end while
        return true
    end function

    function mint_id()
        return crypto.random_token(32)
    end function

    ' CSRF is derived from the session id, never stored: a token that lives
    ' beside the session is one more thing that can be read out of the store.
    function csrf_for(secret, id)
        return crypto.csrf_token(secret, id)
    end function

    ' Constant-time, via crypto's own bytes_equal comparison.
    function csrf_ok(secret, id, token)
        if id = "" or token = "" then
            return false
        end if
        return crypto.csrf_check(token, secret, id)
    end function

    function create(store, username, now)
        id = mint_id()
        rec = { format: 1, id: id, user: username, created: now, seen: now }
        if not store.put(store.ctx, id, rec) then
            return { ok: false, session: {}, message: "could not store the session" }
        end if
        return { ok: true, session: rec, message: "" }
    end function

    function destroy(store, id)
        if not legal_id(id) then
            return false
        end if
        return store.drop(store.ctx, id)
    end function

    ' The session-fixation defence: the id a viewer holds before a privilege
    ' change is never the id they hold after. Named by the platform review as
    ' the rule hand-rolled session code most often omits, which is exactly why
    ' it is a function here rather than two lines someone remembers to write
    ' at each call site.
    function regenerate(store, id, now)
        old = unknown
        if legal_id(id) then
            old = store.get(store.ctx, id)
        end if
        username = ""
        created = now
        if not is_unknown(old) then
            username = string(old["user"])
            created = old["created"]
        end if
        fresh = { format: 1, id: mint_id(), user: username, created: created, seen: now }
        if not store.put(store.ctx, fresh.id, fresh) then
            return { ok: false, session: {}, message: "could not store the session" }
        end if
        if not is_unknown(old) then
            dropped = store.drop(store.ctx, id)
        end if
        return { ok: true, session: fresh, message: "" }
    end function

    ' Returns { ok, session, reason }. An EXPIRED session is reported exactly
    ' as a missing one -- same shape, same caller path -- because to everyone
    ' outside this module they are the same fact: there is no session here.
    ' NOT called `resolve`: web.resolve exists, and gdash lost an afternoon of
    ' GDASH-0 to exactly that collision (F6). The namespace audit caught this
    ' one before a single request was served.
    function active(store, id, now, lim)
        if not legal_id(id) then
            return { ok: false, session: {}, reason: "no session" }
        end if
        rec = store.get(store.ctx, id)
        if is_unknown(rec) then
            return { ok: false, session: {}, reason: "no session" }
        end if
        created = rec["created"]
        seen = rec["seen"]
        if is_unknown(created) or is_unknown(seen) then
            return { ok: false, session: {}, reason: "no session" }
        end if
        if now - created >= lim.absolute then
            dropped = store.drop(store.ctx, id)
            return { ok: false, session: {}, reason: "no session" }
        end if
        if now - seen >= lim.idle then
            dropped = store.drop(store.ctx, id)
            return { ok: false, session: {}, reason: "no session" }
        end if
        ' Idle expiry needs the last-seen time to move, but a write on every
        ' request would make reading a dashboard a write-heavy operation. It
        ' moves at most once a minute, which is a minute of slack on an hour
        ' of idle timeout.
        if now - seen >= lim.touch_after then
            touched = { format: 1, id: rec["id"], user: rec["user"], created: created, seen: now }
            stored = store.put(store.ctx, id, touched)
            return { ok: true, session: touched, reason: "" }
        end if
        return { ok: true, session: rec, reason: "" }
    end function

    ' Crash residue and abandoned browsers. Every session past its absolute
    ' age, whoever left it.
    function sweep(store, now, lim)
        gone = 0
        ids = store.ids(store.ctx)
        i = 0
        while i < count(ids)
            rec = store.get(store.ctx, ids[i])
            if is_unknown(rec) then
                gone += 0
            else
                created = rec["created"]
                seen = rec["seen"]
                if is_unknown(created) or is_unknown(seen) or now - created >= lim.absolute or now - seen >= lim.idle then
                    if store.drop(store.ctx, ids[i]) then
                        gone += 1
                    end if
                end if
            end if
            i += 1
        end while
        return gone
    end function

    ' `Secure` is conditional on the connection, not hardcoded: design §6
    ' expects intranet deployments where TLS is recommended rather than
    ' required, and a hardcoded Secure would silently break login on exactly
    ' those. SameSite=Lax lets an ordinary link into the dashboard work while
    ' refusing cross-site form posts.
    function cookie(name, value, secure, max_age)
        s = name + "=" + value + "; Path=/; HttpOnly; SameSite=Lax"
        if max_age >= 0 then
            s = s + "; Max-Age=" + string(max_age)
        end if
        if secure then
            s = s + "; Secure"
        end if
        return s
    end function

    function clearing_cookie(name, secure)
        return cookie(name, "", secure, 0)
    end function

end library
