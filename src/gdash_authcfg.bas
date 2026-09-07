' gdash — the auth chain, assembled.
'
' The composition root for the provider interface: this is the one module that
' reads <config>/auth.json, validates it, and hands back the ordered list of
' providers. `gdash_auth` is the rules and touches no file; `gdash_users` and
' `gdash_auth_ldap` are the two implementations; this is the wiring.
'
' The order is fixed and is not configurable: LOCAL FIRST, ALWAYS.
'
' Design §8 makes local accounts "the base tier and bootstrap -- first admin
' before any directory exists". That is also the break-glass tier, and
' break-glass only works if it works when the directory does not. A directory
' consulted first would take the local administrator down with it at exactly
' the moment somebody needs to log in and fix the directory configuration.
'
' The cost is real and is stated rather than hidden: a local account shadows a
' directory account of the same name. That shadow is visible in
' `gdash user list`, was created by an operator on purpose, and is removed with
' one command. The reverse failure is neither visible nor removable from
' outside the box.

library gdash_authcfg

    load gdash_paths from "gdash_paths.bas"
    load gdash_auth from "gdash_auth.bas"
    load gdash_users from "gdash_users.bas"
    load gdash_auth_ldap from "gdash_auth_ldap.bas"

    ' { ok, config, errors }. An absent file is a complete, valid, local-only
    ' configuration -- not an error and not a reason to fall open.
    function load_config(p)
        path = gdash_paths.auth_file(p)
        if not gdash_paths.path_exists(path) then
            return { ok: true, config: { format: 1 }, errors: [] }
        end if
        on error goto next
        f {file} = path
        txt = read(f)
        if error then
            return { ok: false, config: { format: 1 }, errors: ["cannot read " + path] }
        end if
        parsed = try_decode(txt)
        if error or not parsed.ok then
            ' Same rule as users.json: a file gdash cannot parse must not
            ' become a file with nothing in it.
            return { ok: false, config: { format: 1 }, errors: ["auth config is not valid JSON"] }
        end if
        if type(parsed.value) != "record" then
            return { ok: false, config: { format: 1 }, errors: ["auth config is not an object"] }
        end if
        problems = gdash_auth.check_config(parsed.value)
        if count(problems) > 0 then
            return { ok: false, config: parsed.value, errors: problems }
        end if
        return { ok: true, config: parsed.value, errors: [] }
    end function

    ' Build the chain from an already-validated config value. Split out from
    ' load_config so tests can assemble a chain without writing a file, and so
    ' `auth check` can build one provider from one profile.
    function chain_from(p, cfg)
        out = [gdash_users.local_provider(p)]
        d = cfg["directory"]
        if is_unknown(d) then
            return out
        end if
        ' The live directory is the seam's shipped implementation; the tests
        ' pass a scripted one to the same function.
        return concat(out, [gdash_auth_ldap.ldap_provider(d, gdash_auth_ldap.live_directory())])
    end function

    ' The chain a request uses. A configuration gdash cannot read yields LOCAL
    ' ONLY: the directory is not guessed at, and the local administrator can
    ' still get in to fix the file. The caller is expected to have reported the
    ' errors; `providers` never silently widens access, only narrows it.
    function providers(p)
        loaded = load_config(p)
        if not loaded.ok then
            return [gdash_users.local_provider(p)]
        end if
        return chain_from(p, loaded.config)
    end function

    function has_directory(cfg)
        return not is_unknown(cfg["directory"])
    end function

end library
