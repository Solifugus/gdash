' gdash — the authentication provider interface.
'
' Policy only. This module opens no connection and reads no file; if it ever
' needs one, the seam is wrong and that is a finding rather than a shortcut
' (brief §3). Everything that touches a directory lives in gdash_auth_ldap;
' everything that touches users.json lives in gdash_users.
'
' A provider is a RECORD OF FUNCTION VALUES -- the seam shape the platform
' required for the session store in GDASH-4, for the same reason: gBASIC has
' function references and not closures, so the context travels as an argument.
'
'   provider = { kind, name, ctx,
'                authenticate: fn(ctx, username, password) -> outcome,
'                identity:     fn(ctx, username)           -> outcome,
'                revalidate:   <seconds; 0 means every request> }
'
'   outcome  = { ok, known, available, message, identity }
'   identity = { name, email, groups, admin }
'
' `known` is a separate fact from `ok`, and it is why the outcome is a record
' rather than a boolean. It means THIS PROVIDER HAS THIS USERNAME, not that
' the password was right. The chain stops at the first provider that says
' `known`, whatever `ok` says -- because without that, one typo at the login
' form costs a failed bind at every configured directory, and in AD a failed
' bind is a step toward a lockout.
'
' `available` is the third fact, and conflating it with the second is the bug
' the platform's `ldap` module refuses to let a caller make: a wrong password
' and an unreachable directory must never be the same answer. The first is
' shown to a person; the second is an operator's problem and must not reach a
' viewer as "your password is wrong", which would send them to reset a
' password that was fine.

library gdash_auth

    ' One refusal for every way of being refused: unknown username, wrong
    ' password, disabled account, directory rejection. Naming which one
    ' happened is a user-enumeration oracle (GDASH-4, unchanged).
    function refusal()
        return "that username and password do not match"
    end function

    function unavailable_message()
        return "Sign-in is unavailable. Ask an administrator."
    end function

    function nobody()
        return { name: "", email: "", groups: [], admin: false }
    end function

    function make_identity(name, email, groups, admin)
        g = groups
        if is_unknown(g) then
            g = []
        end if
        return { name: name, email: string(default(email, "")), groups: g, admin: default(admin, false) = true }
    end function

    function outcome(ok, known, available, message, identity)
        return { ok: ok, known: known, available: available, message: message, identity: identity }
    end function

    ' "I do not have this username." Not an error, not a refusal: the chain
    ' moves on.
    function miss()
        return outcome(false, false, true, "", nobody())
    end function

    ' "I have this username and the credential is wrong." The chain stops.
    function reject()
        return outcome(false, true, true, refusal(), nobody())
    end function

    ' "I could not be asked." Not a refusal at all.
    function unreachable(message)
        return outcome(false, false, false, message, nobody())
    end function

    function accept(identity)
        return outcome(true, true, true, "", identity)
    end function

    ' The `ldap` module's reasons, split into the two things gdash must never
    ' conflate. `invalid_credentials` and `empty_password` are answers about a
    ' credential; everything else is an answer about the directory.
    function operational(reason)
        if reason = "unreachable" then
            return true
        end if
        if reason = "tls_failed" then
            return true
        end if
        if reason = "timeout" then
            return true
        end if
        if reason = "server_error" then
            return true
        end if
        return false
    end function

    ' The chain. Local accounts first and always (brief §2.2): local is the
    ' break-glass tier, and break-glass that needs the directory to be healthy
    ' is not break-glass.
    '
    ' Returns { ok, message, identity, provider, unavailable }. If no provider
    ' authenticated but one could not be asked, the answer is "unavailable" --
    ' never "wrong password".
    function sign_in(providers, username, password)
        blocked = false
        blocked_by = ""
        i = 0
        while i < count(providers)
            pr = providers[i]
            r = pr.authenticate(pr.ctx, username, password)
            if not r.available then
                blocked = true
                blocked_by = pr.name
            else
                if r.ok then
                    return { ok: true, message: "", identity: r.identity, provider: pr.name, unavailable: false }
                end if
                if r.known then
                    return { ok: false, message: refusal(), identity: nobody(), provider: pr.name, unavailable: false }
                end if
            end if
            i += 1
        end while
        if blocked then
            return { ok: false, message: unavailable_message(), identity: nobody(), provider: blocked_by, unavailable: true }
        end if
        return { ok: false, message: refusal(), identity: nobody(), provider: "", unavailable: false }
    end function

    ' Re-resolving an identity that is already signed in: same order, same
    ' rules, no password. Used by revalidation.
    function whois(providers, username)
        blocked = false
        i = 0
        while i < count(providers)
            pr = providers[i]
            r = pr.identity(pr.ctx, username)
            if not r.available then
                blocked = true
            else
                if r.ok then
                    return { ok: true, identity: r.identity, provider: pr.name, unavailable: false }
                end if
                if r.known then
                    ' Known and not ok means disabled, or removed between the
                    ' lookup and now. The session goes.
                    return { ok: false, identity: nobody(), provider: pr.name, unavailable: false }
                end if
            end if
            i += 1
        end while
        if blocked then
            return { ok: false, identity: nobody(), provider: "", unavailable: true }
        end if
        return { ok: false, identity: nobody(), provider: "", unavailable: false }
    end function

    function revalidate_of(providers, name)
        i = 0
        while i < count(providers)
            if providers[i].name = name then
                return providers[i].revalidate
            end if
            i += 1
        end while
        return 0
    end function

    ' Is the identity carried in a session stale? `0` means every request,
    ' which is what the local provider uses -- preserving GDASH-4's behaviour
    ' exactly, because reading users.json is cheap and a directory round trip
    ' is not.
    function revalidation_due(checked, now, every)
        if every <= 0 then
            return true
        end if
        if is_unknown(checked) then
            return true
        end if
        return now - checked >= every
    end function

    ' --- preview-as (brief §2.7) ----------------------------------------
    '
    ' It substitutes the injected user_* params and NOTHING ELSE. It does not
    ' re-run authorization as the assumed identity: you cannot preview-as your
    ' way into a dashboard you may not open, and you cannot preview-as your
    ' way into being an admin. Anything else would be privilege escalation
    ' with a friendly name.

    function preview_allowed(mode, may_edit)
        if mode != "draft" then
            return false
        end if
        return may_edit
    end function

    ' The assumed identity is TYPED by the editor, not looked up: "show me
    ' this as a plausible member of Shipping" is the real question, and
    ' requiring a colleague's account to answer it invites borrowing one.
    ' `admin` is false always -- see above.
    function preview_identity(name, email, groups_text)
        g = []
        if trim(string(default(groups_text, ""))) != "" then
            raw = split(string(groups_text), ",")
            i = 0
            while i < count(raw)
                one = trim(raw[i])
                if one != "" then
                    g = concat(g, [one])
                end if
                i += 1
            end while
        end if
        return make_identity(trim(string(default(name, ""))), trim(string(default(email, ""))), g, false)
    end function

    ' --- configuration validation ---------------------------------------
    '
    ' Pure: it is handed the decoded value, never a path. Refusals are pinned
    ' byte-for-byte in tests/goldens/auth_validation.golden, because a message
    ' an operator reads at 2am is a contract.

    function _is_whole(v, low)
        if is_unknown(v) then
            return false
        end if
        if type(v) != "number" then
            return false
        end if
        if v != round(v, 0) then
            return false
        end if
        return v >= low
    end function

    function _names_ok(list, label, errors)
        out = errors
        if is_unknown(list) then
            return out
        end if
        if type(list) != "array" then
            return concat(out, ["'" + label + "' must be an array of group names; a bare string is not a list of one"])
        end if
        i = 0
        while i < count(list)
            if type(list[i]) != "string" or trim(string(list[i])) = "" then
                return concat(out, ["'" + label + "' contains an entry that is not a group name"])
            end if
            i += 1
        end while
        return out
    end function

    function check_config(cfg)
        errors = []
        if is_unknown(cfg) then
            return ["auth config is not an object"]
        end if
        if type(cfg["format"]) != "number" or cfg["format"] != 1 then
            errors = concat(errors, ["unsupported auth config format: " + string(default(cfg["format"], "none")) + " (this build reads format 1)"])
        end if
        d = cfg["directory"]
        if is_unknown(d) then
            ' No directory is a complete, valid configuration: local only,
            ' which is exactly GDASH-4 and still fails closed.
            return errors
        end if

        kind = string(default(d["kind"], ""))
        if kind != "ldap" then
            errors = concat(errors, ["directory has kind '" + kind + "'; this build implements 'ldap'"])
        end if
        if trim(string(default(d["host"], ""))) = "" then
            errors = concat(errors, ["directory has no 'host'"])
        end if

        sec = string(default(d["security"], ""))
        if sec = "" then
            errors = concat(errors, ["directory has no 'security'; it must be 'ldaps', 'starttls' or 'plain', and there is no default because a cleartext bind must be a word somebody typed"])
        else if sec != "ldaps" and sec != "starttls" and sec != "plain" then
            errors = concat(errors, ["directory has security '" + sec + "'; it must be 'ldaps', 'starttls' or 'plain'"])
        end if
        if not is_unknown(d["port"]) then
            if not _is_whole(d["port"], 1) then
                errors = concat(errors, ["directory has 'port' of '" + string(d["port"]) + "'; it must be a whole number of at least 1"])
            end if
        end if

        tpl = string(default(d["user_dn_template"], ""))
        us = d["user_search"]
        if tpl != "" and not is_unknown(us) then
            errors = concat(errors, ["directory sets both 'user_dn_template' and 'user_search'; it names exactly one way to find a user"])
        else if tpl = "" and is_unknown(us) then
            errors = concat(errors, ["directory sets neither 'user_dn_template' nor 'user_search'; it names exactly one way to find a user"])
        end if
        if tpl != "" and not contains(tpl, "{user}") then
            errors = concat(errors, ["'user_dn_template' contains no '{user}', so every login would construct the same DN"])
        end if
        if not is_unknown(us) then
            if trim(string(default(us["base"], ""))) = "" then
                errors = concat(errors, ["'user_search' has no 'base'"])
            end if
            uf = string(default(us["filter"], ""))
            if uf = "" then
                errors = concat(errors, ["'user_search' has no 'filter'"])
            else if not contains(uf, "{user}") then
                errors = concat(errors, ["'user_search' filter contains no '{user}', so it would match the same entry for every login"])
            end if
            sc = string(default(us["scope"], "sub"))
            if sc != "base" and sc != "one" and sc != "sub" then
                errors = concat(errors, ["'user_search' has scope '" + sc + "'; it must be 'base', 'one' or 'sub'"])
            end if
        end if
        if trim(string(default(d["bind_password"], ""))) != "" and trim(string(default(d["bind_dn"], ""))) = "" then
            errors = concat(errors, ["directory sets 'bind_password' with no 'bind_dn'"])
        end if

        ' The G5-4 ruling: named, with no default. Guessing here produces a
        ' plausible answer rather than a failure -- stock OpenLDAP has no
        ' memberOf at all, and zero groups is a legitimate answer, so a wrong
        ' guess refuses everyone while the log shows successful logins.
        gs = string(default(d["group_strategy"], ""))
        if gs = "" then
            errors = concat(errors, ["directory has no 'group_strategy'; it must be 'memberof' (read the attribute) or 'search' (find groups whose 'member' is the user's DN), and there is no default because stock OpenLDAP populates no memberOf and zero groups is a legitimate answer"])
        else if gs != "memberof" and gs != "search" then
            errors = concat(errors, ["directory has group_strategy '" + gs + "'; it must be 'memberof' or 'search'"])
        end if
        if gs = "search" then
            if trim(string(default(d["group_base"], ""))) = "" then
                errors = concat(errors, ["group_strategy 'search' needs a 'group_base' to search under"])
            end if
            gf = string(default(d["group_filter"], "(member={dn})"))
            if not contains(gf, "{dn}") then
                errors = concat(errors, ["'group_filter' contains no '{dn}', so it would return the same groups for every user"])
            end if
        end if
        gn = string(default(d["group_names"], "rdn"))
        if gn != "rdn" and gn != "dn" then
            errors = concat(errors, ["directory has group_names '" + gn + "'; it must be 'rdn' (the leftmost value) or 'dn' (the whole distinguished name)"])
        end if

        if not is_unknown(d["revalidate"]) then
            if not _is_whole(d["revalidate"], 0) then
                errors = concat(errors, ["directory has 'revalidate' of '" + string(d["revalidate"]) + "'; it must be a whole number of seconds, zero or more"])
            end if
        end if
        errors = _names_ok(d["admin_groups"], "admin_groups", errors)
        return errors
    end function

end library
