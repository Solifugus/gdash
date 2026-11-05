' A scripted directory, for the LDAP provider's hermetic tests.
'
' gdash ships one implementation of the seam: gdash_auth_ldap.live_directory,
' four thin wrappers over the platform's `ldap` module. This is the other one.
' It speaks the same four functions and answers from a plan held in its ctx.
'
' It exists because a HEALTHY directory cannot produce the answers the policy
' layer's failure branches were written for: a search that succeeds with zero
' entries, an entry whose `dn` disagrees with the filter that found it, a
' service account whose own bind fails, `tls_failed` on demand. Those branches
' are most of gdash_auth_ldap, and until the seam existed none of them ran
' outside an opt-in container.
'
' plan = {
'   open_fail:   ""  or "server_error" or "no_ldap",
'   binds:       { "<dn>": { ok, reason } },   anything unlisted: invalid_credentials
'   rules:       [ { base, filter_has, entries } ],  first match answers
'   search_fail: false,
'   log:         <path>   -- one line per call, so opens and closes can be counted
' }
'
' gBASIC has function references and not closures, so the plan travels as ctx.
' Call accounting goes to a FILE for the same reason a library cannot hold
' mutable state.

library directory_double

    function _note(ctx, line)
        path = string(default(ctx["log"], ""))
        if path = "" then
            return false
        end if
        on error goto next
        f {file} = path
        prior = ""
        if exists(f) then
            prior = read(f)
        end if
        write(f, prior + line + chr(10))
        if error then
            return false
        end if
        return true
    end function

    function calls(path, kind)
        on error goto next
        f {file} = path
        if not exists(f) then
            return 0
        end if
        txt = read(f)
        if error then
            return 0
        end if
        n = 0
        for each line in split(txt, chr(10))
            if line = kind then
                n += 1
            end if
        next
        return n
    end function

    function open(ctx, config)
        noted = _note(ctx, "open")
        fail = string(default(ctx["open_fail"], ""))
        if fail != "" then
            return { ok: false, conn: unknown, reason: fail }
        end if
        ' The "connection" is just a token; the double is stateless per call.
        return { ok: true, conn: { id: 1 }, reason: "" }
    end function

    function bind(ctx, conn, dn, password)
        noted = _note(ctx, "bind:" + dn)
        want = ctx["binds"]
        if is_unknown(want) then
            return { ok: false, reason: "invalid_credentials" }
        end if
        answer = want[dn]
        if is_unknown(answer) then
            ' Unlisted DN: the same answer a real directory gives for both a
            ' wrong password and a DN that is not there (G5-3).
            return { ok: false, reason: "invalid_credentials" }
        end if
        ' Bound out rather than compared inline, for the reason given in
        ' `search` below: `x["k"] = true` inside a record literal does not mean
        ' here what it reads as.
        good = false
        if answer["ok"] = true then
            good = true
        end if
        why = string(default(answer["reason"], ""))
        if good then
            return { ok: true, reason: "" }
        end if
        if why = "" then
            why = "invalid_credentials"
        end if
        return { ok: false, reason: why }
    end function

    ' First rule whose base matches (or is "*") and whose `filter_has` appears
    ' in the filter. No LDAP filter engine here on purpose: the tests say what
    ' the directory returns, which is the whole point of a double.
    function search(ctx, conn, spec)
        noted = _note(ctx, "search:" + string(spec["base"]) + "|" + string(spec["filter"]))
        if default(ctx["search_fail"], false) = true then
            return { ok: false, entries: [] }
        end if
        rules = ctx["rules"]
        if is_unknown(rules) then
            return { ok: true, entries: [] }
        end if
        i = 0
        while i < count(rules)
            r = rules[i]
            ' Bound out into temporaries rather than compared inline. gBASIC's
            ' lexer collides `call(...) = x` with the brace-modifier form, so
            ' an inline comparison on a call result does not parse as intended
            ' -- the same reason stdlib/persist.bas binds out its `_last`.
            want_base = string(default(r["base"], "*"))
            got_base = string(spec["base"])
            base_ok = false
            if want_base = "*" then
                base_ok = true
            end if
            if want_base = got_base then
                base_ok = true
            end if
            has = string(default(r["filter_has"], ""))
            filter_ok = false
            if has = "" then
                filter_ok = true
            end if
            if contains(string(spec["filter"]), has) then
                filter_ok = true
            end if
            if base_ok and filter_ok then
                return { ok: true, entries: default(r["entries"], []) }
            end if
            i += 1
        end while
        ' Matched no rule: a search that SUCCEEDS and returns nothing, which is
        ' what LDAP does and what the policy layer has to tell apart from an
        ' error.
        return { ok: true, entries: [] }
    end function

    function close(ctx, conn)
        if is_unknown(conn) then
            return false
        end if
        noted = _note(ctx, "close")
        return true
    end function

    function wire(plan)
        return { ctx: plan, open: directory_double.open, bind: directory_double.bind,
                 search: directory_double.search, close: directory_double.close }
    end function

end library
