' The provider interface, its escaping, and its chain.
'
' Everything here is hermetic: no directory, no container, no network. The
' policy layer is the half of GDASH-5 that never needed one (finding G5-7),
' and the escaping tests are the half that must never be skipped because a
' container was not running.

' One line per case: label, then the refusals in emission order.
function emit_case(label, cfg)
    load gdash_auth from "../src/gdash_auth.bas"
    got = gdash_auth.check_config(cfg)
    if count(got) = 0 then
        return label + chr(10) + "  (accepted)"
    end if
    return label + chr(10) + "  ERROR " + join(got, chr(10) + "  ERROR ")
end function

' A minimal valid directory profile each case perturbs in exactly one way.
function skeleton()
    return { format: 1, directory: { kind: "ldap", host: "ldap.example.invalid", security: "ldaps",
                                     user_dn_template: "uid={user},ou=people,dc=example,dc=invalid",
                                     group_strategy: "search", group_base: "ou=groups,dc=example,dc=invalid" } }
end function

function dir_case(changes)
    r = skeleton()
    d = r["directory"]
    have = keys(changes)
    i = 0
    while i < count(have)
        if changes[have[i]] = "<<drop>>" then
            d = drop_key(d, have[i])
        else
            d[have[i]] = changes[have[i]]
        end if
        i += 1
    end while
    return { format: 1, directory: d }
end function

function drop_key(rec, key)
    out = {}
    have = keys(rec)
    i = 0
    while i < count(have)
        if have[i] != key then
            out[have[i]] = rec[have[i]]
        end if
        i += 1
    end while
    return out
end function

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_auth from "../src/gdash_auth.bas"
    load gdash_auth_ldap from "../src/gdash_auth_ldap.bas"
    load auth_double from "auth_double.bas"

    s = gdash_test.suite("auth")
    root = args[0]

    ' --- RFC 4515: the filter escape ------------------------------------
    '
    ' The username is attacker-controlled text going into a search filter. An
    ' unescaped `*)(uid=*` is an authentication bypass, not a formatting bug.
    s = gdash_test.eq(s, gdash_auth_ldap.escape_filter("ada"), "ada", "an ordinary name is unchanged")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_filter("*"), "\\2a", "a star is escaped")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_filter("("), "\\28", "an open paren is escaped")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_filter(")"), "\\29", "a close paren is escaped")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_filter("\\"), "\\5c", "a backslash is escaped")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_filter("a" + chr(0) + "b"), "a\\00b", "a NUL is escaped")
    ' Backslash first, or the escapes would be escaped again.
    s = gdash_test.eq(s, gdash_auth_ldap.escape_filter("\\*"), "\\5c\\2a", "a backslash before a star escapes once each")

    injected = gdash_auth_ldap.user_filter({ user_search: { filter: "(uid={user})" } }, "*)(uid=*")
    s = gdash_test.eq(s, injected, "(uid=\\2a\\29\\28uid=\\2a)", "the classic filter injection is inert")
    s = gdash_test.ok(s, not contains(mid(injected, 1, len(injected) - 2), "("), "and leaves exactly one filter clause")

    ' --- RFC 4514: the DN escape ----------------------------------------
    s = gdash_test.eq(s, gdash_auth_ldap.escape_dn("ada"), "ada", "an ordinary name is unchanged")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_dn("a,b"), "a\\2cb", "a comma cannot start a new RDN")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_dn("a=b"), "a\\3db", "an equals cannot start a new attribute")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_dn("a+b"), "a\\2bb", "a plus cannot start a multi-valued RDN")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_dn("\\"), "\\5c", "a backslash is escaped")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_dn(" ada"), "\\20ada", "a leading space is structural")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_dn("ada "), "ada\\20", "so is a trailing one")
    s = gdash_test.eq(s, gdash_auth_ldap.escape_dn("#ada"), "\\23ada", "so is a leading hash")
    ' `replace` truncates its haystack at the first NUL and returns the prefix
    ' with no error (finding G5-9), so both escapes are hand-written scans and
    ' both are asserted to survive one.
    s = gdash_test.eq(s, gdash_auth_ldap.escape_dn("a" + chr(0) + "b"), "a\\00b", "a NUL in a DN is escaped, not swallowed")
    s = gdash_test.eq(s, len(gdash_auth_ldap.escape_filter("ada" + chr(0) + "x")), 7, "and a NUL never truncates the value")

    tpl = { user_dn_template: "uid={user},ou=people,dc=example,dc=invalid" }
    s = gdash_test.eq(s, gdash_auth_ldap.dn_from_template(tpl, "ada"), "uid=ada,ou=people,dc=example,dc=invalid", "a template builds the DN")
    s = gdash_test.eq(s, gdash_auth_ldap.dn_from_template(tpl, "ada,ou=admins"), "uid=ada\\2cou\\3dadmins,ou=people,dc=example,dc=invalid", "and a username cannot graft an RDN onto it")

    ' --- reading a name back out of a DN --------------------------------
    s = gdash_test.eq(s, gdash_auth_ldap.rdn_of("cn=analysts,ou=groups,dc=example,dc=invalid"), "analysts", "the leftmost RDN value is the group name")
    s = gdash_test.eq(s, gdash_auth_ldap.rdn_of("cn=sales\\2c east,ou=groups,dc=x"), "sales, east", "an escaped comma is part of the name, not a separator")
    s = gdash_test.eq(s, gdash_auth_ldap.rdn_of("CN=Finance,OU=Groups,DC=x"), "Finance", "case is the directory's business, not ours")
    s = gdash_test.eq(s, gdash_auth_ldap.rdn_of("analysts"), "analysts", "a bare name survives a DN parse")
    s = gdash_test.eq(s, gdash_auth_ldap.unescape_dn("a\\5cb"), "a\\b", "hex unescaping round-trips a backslash")
    s = gdash_test.eq(s, gdash_auth_ldap.unescape_dn("a\\,b"), "a,b", "and the character-escape spelling works too")

    dns = ["cn=analysts,ou=groups,dc=x", "cn=finance,ou=groups,dc=x"]
    s = gdash_test.eq(s, join(gdash_auth_ldap.group_names(dns, "rdn"), ","), "analysts,finance", "rdn style yields plain names")
    s = gdash_test.eq(s, join(gdash_auth_ldap.group_names(dns, "dn"), ";"), "cn=analysts,ou=groups,dc=x;cn=finance,ou=groups,dc=x", "dn style yields whole DNs")

    ' --- every attribute value is an array, including a single one (G5-3) --
    entry = { dn: "uid=ada,ou=people,dc=x", attributes: { cn: ["Ada"], memberOf: ["cn=analysts,ou=groups,dc=x", "cn=finance,ou=groups,dc=x"] } }
    s = gdash_test.eq(s, count(gdash_auth_ldap.values_of(entry, "cn")), 1, "a single-valued attribute is still an array")
    s = gdash_test.eq(s, count(gdash_auth_ldap.values_of(entry, "memberOf")), 2, "a multi-valued one has its values")
    s = gdash_test.eq(s, count(gdash_auth_ldap.values_of(entry, "mail")), 0, "an absent one is empty, not unknown")
    s = gdash_test.eq(s, gdash_auth_ldap.first_of(entry, "cn"), "Ada", "first_of reads through the array")
    s = gdash_test.eq(s, gdash_auth_ldap.first_of(entry, "mail"), "", "and answers empty for an absent attribute")

    ' --- the group filter -----------------------------------------------
    gf = gdash_auth_ldap.group_filter({}, "uid=ada,ou=people,dc=x")
    s = gdash_test.eq(s, gf, "(member=uid=ada,ou=people,dc=x)", "the default filter is the member= search stock OpenLDAP needs")
    gf2 = gdash_auth_ldap.group_filter({ group_filter: "(&(objectClass=groupOfNames)(member={dn}))" }, "uid=a*b,ou=people,dc=x")
    s = gdash_test.contains_text(s, gf2, "uid=a\\2ab", "a DN going into a filter is filter-escaped")

    ' --- admin comes from a group, and empty means nobody ----------------
    s = gdash_test.ok(s, not gdash_auth_ldap.is_admin({}, ["analysts"]), "no admin_groups means no directory admin")
    s = gdash_test.ok(s, gdash_auth_ldap.is_admin({ admin_groups: ["dash-admins"] }, ["analysts", "dash-admins"]), "a named group makes an admin")
    s = gdash_test.ok(s, not gdash_auth_ldap.is_admin({ admin_groups: ["dash-admins"] }, ["analysts"]), "and only that group")

    ' --- the chain -------------------------------------------------------
    '
    ' Two doubles standing in for local and the directory, so the ORDER and the
    ' SHORT-CIRCUIT are tested without either shipped implementation.
    local_ctx = { name: "local", up: true, people: { ada: { password: "fake-local-pw", email: "ada@local.invalid", groups: ["ops"], admin: true },
                                                    gone: { password: "fake", groups: [], disabled: true } } }
    dir_ctx = { name: "directory", up: true, people: { ada: { password: "fake-directory-pw", email: "ada@corp.invalid", groups: ["analysts"] },
                                                      bo: { password: "fake-bo-pw", email: "bo@corp.invalid", groups: ["finance"] } } }
    chain = [auth_double.provider(local_ctx, 0), auth_double.provider(dir_ctx, 300)]

    ' A name local holds is answered by local, and the directory is never asked.
    hit = gdash_auth.sign_in(chain, "ada", "fake-local-pw")
    s = gdash_test.ok(s, hit.ok, "local answers for a name it holds")
    s = gdash_test.eq(s, hit.provider, "local", "and it is local that answered")
    s = gdash_test.eq(s, hit.identity.email, "ada@local.invalid", "with local's identity, not the directory's")

    ' The short-circuit: local knows `ada`, so a wrong password STOPS THERE.
    ' Without this, one typo costs a failed bind at every directory, and in AD
    ' a failed bind is a step toward a lockout.
    shadowed = gdash_auth.sign_in(chain, "ada", "fake-directory-pw")
    s = gdash_test.ok(s, not shadowed.ok, "a local account shadows a directory account of the same name")
    s = gdash_test.eq(s, shadowed.provider, "local", "and the directory is never consulted for it")
    s = gdash_test.eq(s, shadowed.message, gdash_auth.refusal(), "the refusal is the one refusal")

    ' A name local does not hold reaches the directory.
    reached = gdash_auth.sign_in(chain, "bo", "fake-bo-pw")
    s = gdash_test.ok(s, reached.ok, "a name local does not hold reaches the directory")
    s = gdash_test.eq(s, reached.provider, "directory", "and the directory answers it")
    s = gdash_test.eq(s, join(reached.identity.groups, ","), "finance", "with the directory's groups")
    s = gdash_test.ok(s, not reached.identity.admin, "and no admin it was not given")

    ' A disabled local account stops the chain: disabling somebody locally must
    ' not re-enable them in the directory.
    stopped = gdash_auth.sign_in(chain, "gone", "fake")
    s = gdash_test.ok(s, not stopped.ok, "a disabled local account is refused")
    s = gdash_test.eq(s, stopped.provider, "local", "without falling through to the directory")

    ' Nobody at all.
    nowhere = gdash_auth.sign_in(chain, "nobody", "fake")
    s = gdash_test.ok(s, not nowhere.ok, "an unknown name is refused")
    s = gdash_test.ok(s, not nowhere.unavailable, "and that is a refusal, not an outage")
    s = gdash_test.eq(s, nowhere.message, gdash_auth.refusal(), "with the same message as a wrong password")

    ' --- a directory that is down is never a wrong password --------------
    down_ctx = { name: "directory", up: false, people: {} }
    down_chain = [auth_double.provider(local_ctx, 0), auth_double.provider(down_ctx, 300)]
    outage = gdash_auth.sign_in(down_chain, "bo", "fake-bo-pw")
    s = gdash_test.ok(s, not outage.ok, "a directory that is down cannot sign anyone in")
    s = gdash_test.ok(s, outage.unavailable, "and says so")
    s = gdash_test.eq(s, outage.message, gdash_auth.unavailable_message(), "with the operator's message, not the viewer's")
    s = gdash_test.ok(s, outage.message != gdash_auth.refusal(), "never 'your password is wrong' for a directory outage")

    ' ...but local still works while it is down. That is the whole reason
    ' local is first.
    breakglass = gdash_auth.sign_in(down_chain, "ada", "fake-local-pw")
    s = gdash_test.ok(s, breakglass.ok, "the local administrator can still get in while the directory is down")

    ' --- the ldap module's reasons, split the way gdash must split them ---
    s = gdash_test.ok(s, not gdash_auth.operational("invalid_credentials"), "a wrong password is about a credential")
    s = gdash_test.ok(s, not gdash_auth.operational("empty_password"), "so is an empty one")
    s = gdash_test.ok(s, gdash_auth.operational("unreachable"), "an unreachable directory is not")
    s = gdash_test.ok(s, gdash_auth.operational("tls_failed"), "nor is a TLS failure")
    s = gdash_test.ok(s, gdash_auth.operational("timeout"), "nor a timeout")
    s = gdash_test.ok(s, gdash_auth.operational("server_error"), "nor a server error")

    ' --- re-resolving an identity without a password ---------------------
    who = gdash_auth.whois(chain, "bo")
    s = gdash_test.ok(s, who.ok, "an identity re-resolves")
    s = gdash_test.eq(s, join(who.identity.groups, ","), "finance", "with current groups")
    gone_now = gdash_auth.whois(chain, "nobody")
    s = gdash_test.ok(s, not gone_now.ok, "a user who is gone does not re-resolve")
    s = gdash_test.ok(s, not gone_now.unavailable, "and that is a real absence")
    blocked = gdash_auth.whois(down_chain, "bo")
    s = gdash_test.ok(s, not blocked.ok, "a down directory cannot re-resolve")
    s = gdash_test.ok(s, blocked.unavailable, "and says the session should stand, not fall")

    ' --- revalidation ----------------------------------------------------
    s = gdash_test.ok(s, gdash_auth.revalidation_due(1000, 1000, 0), "revalidate 0 means every request")
    s = gdash_test.ok(s, not gdash_auth.revalidation_due(1000, 1299, 300), "before the interval, the cached identity stands")
    s = gdash_test.ok(s, gdash_auth.revalidation_due(1000, 1300, 300), "at the interval, it is re-resolved")
    s = gdash_test.ok(s, gdash_auth.revalidation_due(unknown, 1300, 300), "a session that never recorded a check is due")
    s = gdash_test.eq(s, gdash_auth.revalidate_of(chain, "directory"), 300, "the interval comes from the provider")
    s = gdash_test.eq(s, gdash_auth.revalidate_of(chain, "local"), 0, "and local's is zero")

    ' --- preview-as ------------------------------------------------------
    s = gdash_test.ok(s, gdash_auth.preview_allowed("draft", true), "an editor may preview-as in draft")
    s = gdash_test.ok(s, not gdash_auth.preview_allowed("published", true), "nobody may in published")
    s = gdash_test.ok(s, not gdash_auth.preview_allowed("draft", false), "and a non-editor may not at all")

    pv = gdash_auth.preview_identity("Test Person", "test@example.invalid", " shipping , finance ")
    s = gdash_test.eq(s, pv.name, "Test Person", "the assumed name is what was typed")
    s = gdash_test.eq(s, join(pv.groups, "|"), "shipping|finance", "the assumed groups are split and trimmed")
    s = gdash_test.ok(s, not pv.admin, "and preview-as never grants admin")
    s = gdash_test.eq(s, count(gdash_auth.preview_identity("x", "", "").groups), 0, "no groups typed is no groups")
    s = gdash_test.eq(s, count(gdash_auth.preview_identity("x", "", " , ,, ").groups), 0, "and neither is a row of commas")

    ' --- the configuration catalog, pinned byte-for-byte -----------------
    lines = []
    lines = concat(lines, [emit_case("valid, template mode", skeleton())])
    lines = concat(lines, [emit_case("valid, local only", { format: 1 })])
    lines = concat(lines, [emit_case("format missing", { directory: skeleton()["directory"] })])
    lines = concat(lines, [emit_case("kind unknown", dir_case({ kind: "kerberos" }))])
    lines = concat(lines, [emit_case("host missing", dir_case({ host: "<<drop>>" }))])
    lines = concat(lines, [emit_case("security missing", dir_case({ security: "<<drop>>" }))])
    lines = concat(lines, [emit_case("security unknown", dir_case({ security: "none" }))])
    lines = concat(lines, [emit_case("port not a whole number", dir_case({ port: 636.5 }))])
    lines = concat(lines, [emit_case("both ways to find a user", dir_case({ user_search: { base: "ou=people,dc=x", filter: "(uid={user})" } }))])
    lines = concat(lines, [emit_case("neither way to find a user", dir_case({ user_dn_template: "<<drop>>" }))])
    lines = concat(lines, [emit_case("template without a placeholder", dir_case({ user_dn_template: "uid=svc,ou=people,dc=x" }))])
    lines = concat(lines, [emit_case("user_search without a base", dir_case({ user_dn_template: "<<drop>>", user_search: { filter: "(uid={user})" } }))])
    lines = concat(lines, [emit_case("user_search without a filter", dir_case({ user_dn_template: "<<drop>>", user_search: { base: "ou=people,dc=x" } }))])
    lines = concat(lines, [emit_case("user_search filter without a placeholder", dir_case({ user_dn_template: "<<drop>>", user_search: { base: "ou=people,dc=x", filter: "(objectClass=person)" } }))])
    lines = concat(lines, [emit_case("user_search scope unknown", dir_case({ user_dn_template: "<<drop>>", user_search: { base: "ou=people,dc=x", filter: "(uid={user})", scope: "deep" } }))])
    lines = concat(lines, [emit_case("bind_password without a bind_dn", dir_case({ bind_password: "obviously-fake" }))])
    lines = concat(lines, [emit_case("group_strategy missing", dir_case({ group_strategy: "<<drop>>", group_base: "<<drop>>" }))])
    lines = concat(lines, [emit_case("group_strategy unknown", dir_case({ group_strategy: "guess" }))])
    lines = concat(lines, [emit_case("search strategy without a group_base", dir_case({ group_base: "<<drop>>" }))])
    lines = concat(lines, [emit_case("group_filter without a placeholder", dir_case({ group_filter: "(objectClass=groupOfNames)" }))])
    lines = concat(lines, [emit_case("group_names unknown", dir_case({ group_names: "cn" }))])
    lines = concat(lines, [emit_case("revalidate not a whole number", dir_case({ revalidate: -5 }))])
    lines = concat(lines, [emit_case("admin_groups as a bare string", dir_case({ admin_groups: "dash-admins" }))])
    lines = concat(lines, [emit_case("admin_groups with an empty entry", dir_case({ admin_groups: ["ok", " "] }))])

    actual = join(lines, chr(10)) + chr(10)
    gpath = "tests/goldens/auth_validation.golden"

    if default(env("GDASH_UPDATE_GOLDENS"), "0") = "1" then
        gf3 {file} = gpath
        write(gf3, actual)
        print("goldens rewritten: " + gpath)
        exit(0)
    end if

    ef {file} = gpath
    if not exists(ef) then
        print to error "golden file missing: " + gpath
        print to error "regenerate with GDASH_UPDATE_GOLDENS=1"
        exit(1)
    end if
    expected = read(ef)
    if actual = expected then
        s = gdash_test.ok(s, true, "auth configuration catalog matches its golden")
    else
        af {file} = root + "/auth_validation.actual"
        write(af, actual)
        s = gdash_test.ok(s, false, "auth configuration catalog DIFFERS from its golden -- actual written to " + root + "/auth_validation.actual")
    end if

    exit(gdash_test.report(s))
end program
