' The LDAP provider's POLICY, against a scripted directory.
'
' Hermetic: no container, no network, no opt-in switch. Until the seam existed
' (GDASH-6 §2.3) roughly four hundred lines of authentication code -- every
' failure branch in gdash_auth_ldap -- ran only under GDASH_LDAP_TEST=1, which
' from a clean checkout means never.
'
' The live runner still exists and still passes; it proves the seam matches a
' real server. This proves the logic on top of it, including the answers a
' healthy server will not give you on request.

function ctx_for(cfg, plan)
    load gdash_auth_ldap from "../src/gdash_auth_ldap.bas"
    load directory_double from "directory_double.bas"
    return gdash_auth_ldap.directory_ctx(cfg, directory_double.wire(plan))
end function

function fresh_log(path)
    ' Truncated per test rather than trusted to be absent: the accounting is
    ' append-only, so a log left over from an earlier run would inflate every
    ' count and the test would depend on the harness handing it a clean
    ' directory.
    f {file} = path
    write(f, "")
    return path
end function

function one_bind(dn, answer)
    b = {}
    b[dn] = answer
    return b
end function

function two_binds(dn1, a1, dn2, a2)
    b = {}
    b[dn1] = a1
    b[dn2] = a2
    return b
end function

function person(dn, mail, cn, member_of)
    a = { mail: [mail], cn: [cn] }
    if count(member_of) > 0 then
        a["memberOf"] = member_of
    end if
    return { dn: dn, attributes: a }
end function

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_auth from "../src/gdash_auth.bas"
    load gdash_auth_ldap from "../src/gdash_auth_ldap.bas"
    load directory_double from "directory_double.bas"

    s = gdash_test.suite("directory")
    root = args[0]

    people = "ou=people,dc=example,dc=invalid"
    groups = "ou=groups,dc=example,dc=invalid"
    ada_dn = "uid=ada," + people

    tpl = { kind: "ldap", name: "corp", host: "d.example.invalid", security: "ldaps",
            user_dn_template: "uid={user}," + people,
            group_strategy: "search", group_base: groups }

    group_rule = { base: groups, filter_has: "member=", entries: [
        { dn: "cn=analysts," + groups, attributes: { cn: ["analysts"] } },
        { dn: "cn=finance," + groups, attributes: { cn: ["finance"] } } ] }

    ' --- the happy path, template mode -----------------------------------
    plan = { binds: one_bind(ada_dn, { ok: true }), rules: [group_rule], log: fresh_log(root + "/l1.txt") }
    good = gdash_auth_ldap.ldap_authenticate(ctx_for(tpl, plan), "ada", "fake-pw")
    s = gdash_test.ok(s, good.ok, "a template-mode bind authenticates")
    s = gdash_test.eq(s, join(good.identity.groups, ","), "analysts,finance", "and a member= search resolves the groups")
    s = gdash_test.ok(s, not good.identity.admin, "with no admin it was not given")

    ' EVERY CONNECTION IS CLOSED, on every path. A directory that leaks a
    ' connection per login is a directory that stops answering.
    s = gdash_test.eq(s, directory_double.calls(root + "/l1.txt", "close"), directory_double.calls(root + "/l1.txt", "open"), "every connection opened is closed")

    ' --- the credential answers -------------------------------------------
    bad = gdash_auth_ldap.ldap_authenticate(ctx_for(tpl, { binds: one_bind(ada_dn, { ok: false, reason: "invalid_credentials" }), log: fresh_log(root + "/l2.txt") }), "ada", "wrong")
    s = gdash_test.ok(s, not bad.ok, "a wrong password is refused")
    s = gdash_test.ok(s, bad.known, "and the chain stops, because the directory answered")
    s = gdash_test.ok(s, bad.available, "with no suggestion the directory is down")
    s = gdash_test.eq(s, directory_double.calls(root + "/l2.txt", "close"), directory_double.calls(root + "/l2.txt", "open"), "a refused bind still closes its connection")

    ' --- the operational answers, which must never look like a bad password -
    ' A healthy directory will not produce these on demand. That is the point.
    i = 0
    reasons = ["unreachable", "tls_failed", "timeout", "server_error"]
    while i < count(reasons)
        out = gdash_auth_ldap.ldap_authenticate(ctx_for(tpl, { binds: one_bind(ada_dn, { ok: false, reason: reasons[i] }) }), "ada", "fake-pw")
        s = gdash_test.ok(s, not out.ok, reasons[i] + " cannot sign anyone in")
        s = gdash_test.ok(s, not out.available, reasons[i] + " reports the directory unavailable")
        s = gdash_test.ok(s, not out.known, reasons[i] + " never claims the credential was wrong")
        i += 1
    end while

    ' connect itself failing
    dead = gdash_auth_ldap.ldap_authenticate(ctx_for(tpl, { open_fail: "server_error" }), "ada", "fake-pw")
    s = gdash_test.ok(s, not dead.available, "a connection that cannot be opened is an outage")
    nobuild = gdash_auth_ldap.ldap_authenticate(ctx_for(tpl, { open_fail: "no_ldap" }), "ada", "fake-pw")
    s = gdash_test.ok(s, not nobuild.available, "and so is a build with no ldap support")
    s = gdash_test.ok(s, not nobuild.known, "which is not a statement about the password")

    ' --- an empty password never travels ----------------------------------
    blankplan = { binds: one_bind(ada_dn, { ok: true }), log: fresh_log(root + "/l3.txt") }
    blank = gdash_auth_ldap.ldap_authenticate(ctx_for(tpl, blankplan), "ada", "")
    s = gdash_test.ok(s, not blank.ok, "an empty password cannot sign anyone in")
    s = gdash_test.eq(s, directory_double.calls(root + "/l3.txt", "open"), 0, "and the directory is never contacted at all")

    ' --- search mode -------------------------------------------------------
    svc_dn = "cn=svc,dc=example,dc=invalid"
    srch = { kind: "ldap", name: "corp", host: "d.example.invalid", security: "ldaps",
             user_search: { base: people, scope: "sub", filter: "(uid={user})" },
             bind_dn: svc_dn, bind_password: "obviously-fake",
             group_strategy: "search", group_base: groups }
    user_rule = { base: people, filter_has: "uid=ada", entries: [person(ada_dn, "ada@example.invalid", "Ada", [])] }
    srch_plan = { binds: two_binds(svc_dn, { ok: true }, ada_dn, { ok: true }), rules: [user_rule, group_rule], log: fresh_log(root + "/l4.txt") }

    found = gdash_auth_ldap.ldap_authenticate(ctx_for(srch, srch_plan), "ada", "fake-pw")
    s = gdash_test.ok(s, found.ok, "a service-account search finds the user and binds as them")
    s = gdash_test.eq(s, found.identity.email, "ada@example.invalid", "reading the mail attribute it asked for")
    s = gdash_test.eq(s, join(found.identity.groups, ","), "analysts,finance", "with their groups")
    s = gdash_test.eq(s, directory_double.calls(root + "/l4.txt", "close"), directory_double.calls(root + "/l4.txt", "open"), "and closes both connections")

    ' The service account's OWN bind failing is an operator's problem, never a
    ' viewer's -- it must not surface as a bad password.
    svcfail = gdash_auth_ldap.ldap_authenticate(ctx_for(srch, { binds: one_bind(svc_dn, { ok: false, reason: "invalid_credentials" }), rules: [user_rule] }), "ada", "fake-pw")
    s = gdash_test.ok(s, not svcfail.ok, "a service account that cannot bind signs nobody in")
    s = gdash_test.ok(s, not svcfail.available, "and is reported as an outage, not a wrong password")

    ' A SEARCH THAT SUCCEEDS AND RETURNS NOTHING. With a service account this
    ' is authoritative -- the user is not there -- so the chain moves on.
    gone = gdash_auth_ldap.ldap_authenticate(ctx_for(srch, { binds: one_bind(svc_dn, { ok: true }), rules: [] }), "nobody", "fake-pw")
    s = gdash_test.ok(s, not gone.ok, "a search matching nothing does not authenticate")
    s = gdash_test.ok(s, not gone.known, "and reports the username as not this provider's")
    s = gdash_test.ok(s, gone.available, "which is not the same as the directory being down")

    ' ...but WITHOUT a service account the same empty result is not
    ' authoritative: "the directory would not tell me" and "there is no such
    ' user" are two facts, and conflating them is how a session gets destroyed
    ' for the wrong reason.
    anon = { kind: "ldap", name: "corp", host: "d.example.invalid", security: "ldaps",
             user_search: { base: people, scope: "sub", filter: "(uid={user})" },
             group_strategy: "search", group_base: groups }
    unsure = gdash_auth_ldap.ldap_authenticate(ctx_for(anon, { rules: [] }), "nobody", "fake-pw")
    s = gdash_test.ok(s, not unsure.ok, "an anonymous search matching nothing does not authenticate")
    s = gdash_test.ok(s, not unsure.available, "and says so rather than declaring the user absent")

    ' A search that FAILS is never mistaken for one that returned nothing.
    broke = gdash_auth_ldap.ldap_authenticate(ctx_for(srch, { binds: one_bind(svc_dn, { ok: true }), search_fail: true }), "ada", "fake-pw")
    s = gdash_test.ok(s, not broke.available, "a search that errors is an outage, not an absence")

    ' The directory is the authority on its own DNs: gdash binds as the dn the
    ' search RETURNED, not the one it might have guessed from the filter.
    odd_dn = "uid=ada,ou=contractors,dc=example,dc=invalid"
    odd_rule = { base: people, filter_has: "uid=ada", entries: [person(odd_dn, "ada@example.invalid", "Ada", [])] }
    odd = gdash_auth_ldap.ldap_authenticate(ctx_for(srch, { binds: two_binds(svc_dn, { ok: true }, odd_dn, { ok: true }), rules: [odd_rule, group_rule] }), "ada", "fake-pw")
    s = gdash_test.ok(s, odd.ok, "an entry whose dn is not where the filter looked is still bound as itself")

    ' --- group strategies --------------------------------------------------
    '
    ' G5-4, hermetically: the same directory that yields two groups under
    ' `search` yields NONE under `memberof`, because the overlay is not on.
    ' This is why the strategy is named in configuration with no default.
    ' The plan below is the SAME directory the `search` tests used -- group_rule
    ' is in it, and group_base is configured, so a member= search would find
    ' two groups. memberof must still resolve none, because the attribute is
    ' empty and the strategy was named. Without those two lines the test would
    ' pass for a directory that simply had no groups anywhere, which proves
    ' nothing: mutation-testing this file caught exactly that, by making
    ' memberof silently fall back to a search and watching the suite stay green.
    mof = { kind: "ldap", name: "corp", host: "d.example.invalid", security: "ldaps",
            user_dn_template: "uid={user}," + people, group_strategy: "memberof",
            group_base: groups }
    bare_entry = { base: ada_dn, entries: [person(ada_dn, "ada@example.invalid", "Ada", [])] }
    silent = gdash_auth_ldap.ldap_authenticate(ctx_for(mof, { binds: one_bind(ada_dn, { ok: true }), rules: [bare_entry, group_rule] }), "ada", "fake-pw")
    s = gdash_test.ok(s, silent.ok, "the memberof strategy still authenticates")
    s = gdash_test.eq(s, count(silent.identity.groups), 0, "and resolves NO groups from a directory whose memberOf is empty")
    s = gdash_test.ok(s, count(gdash_auth_ldap.groups_for(directory_double.wire({ rules: [group_rule] }), tpl, { id: 1 }, ada_dn, {})) = 2, "even though a member= search of that same directory finds two")

    withattr = [{ base: ada_dn, entries: [person(ada_dn, "ada@example.invalid", "Ada", ["cn=analysts," + groups, "cn=finance," + groups])] }]
    populated = gdash_auth_ldap.ldap_authenticate(ctx_for(mof, { binds: one_bind(ada_dn, { ok: true }), rules: withattr }), "ada", "fake-pw")
    s = gdash_test.eq(s, join(populated.identity.groups, ","), "analysts,finance", "memberOf values become plain group names")

    as_dns = { kind: "ldap", name: "corp", host: "d.example.invalid", security: "ldaps",
               user_dn_template: "uid={user}," + people, group_strategy: "memberof", group_names: "dn" }
    whole = gdash_auth_ldap.ldap_authenticate(ctx_for(as_dns, { binds: one_bind(ada_dn, { ok: true }), rules: withattr }), "ada", "fake-pw")
    ' Compared as a joined string rather than by indexing [0]: an assertion
    ' that indexes into an empty array CRASHES the suite instead of failing it,
    ' and takes every assertion after it down too. Found by mutation-testing
    ' this very file.
    s = gdash_test.eq(s, join(whole.identity.groups, ";"), "cn=analysts," + groups + ";cn=finance," + groups, "group_names 'dn' keeps the whole distinguished name")

    ' A group entry with no name attribute falls back to its RDN rather than
    ' contributing an empty group name that no record could ever match.
    nameless = { base: groups, filter_has: "member=", entries: [{ dn: "cn=shipping," + groups, attributes: {} }] }
    fell_back = gdash_auth_ldap.ldap_authenticate(ctx_for(tpl, { binds: one_bind(ada_dn, { ok: true }), rules: [nameless] }), "ada", "fake-pw")
    s = gdash_test.eq(s, join(fell_back.identity.groups, ","), "shipping", "a group with no cn falls back to its RDN")

    ' --- admin comes from a group -----------------------------------------
    boss = { kind: "ldap", name: "corp", host: "d.example.invalid", security: "ldaps",
             user_dn_template: "uid={user}," + people, group_strategy: "search",
             group_base: groups, admin_groups: ["finance"] }
    promoted = gdash_auth_ldap.ldap_authenticate(ctx_for(boss, { binds: one_bind(ada_dn, { ok: true }), rules: [group_rule] }), "ada", "fake-pw")
    s = gdash_test.ok(s, promoted.identity.admin, "a named admin group makes an administrator")

    ' --- identity without a password --------------------------------------
    who = gdash_auth_ldap.ldap_identity(ctx_for(srch, srch_plan), "ada")
    s = gdash_test.ok(s, who.ok, "an identity re-resolves with no password")
    s = gdash_test.eq(s, join(who.identity.groups, ","), "analysts,finance", "with current groups")

    left = gdash_auth_ldap.ldap_identity(ctx_for(srch, { binds: one_bind(svc_dn, { ok: true }), rules: [] }), "nobody")
    s = gdash_test.ok(s, not left.ok, "a user the directory no longer has does not re-resolve")
    s = gdash_test.ok(s, left.available, "and with a service account that is a real absence")

    cant = gdash_auth_ldap.ldap_identity(ctx_for(anon, { rules: [] }), "nobody")
    s = gdash_test.ok(s, not cant.available, "without one, it is 'cannot say' -- so the session stands")

    outage = gdash_auth_ldap.ldap_identity(ctx_for(srch, { open_fail: "server_error" }), "ada")
    s = gdash_test.ok(s, not outage.available, "and an unreachable directory never reports a user as gone")

    ' --- the diagnostic ----------------------------------------------------
    told = gdash_auth_ldap.explain(ctx_for(srch, srch_plan), "ada")
    s = gdash_test.ok(s, told.ok, "auth check resolves the user")
    s = gdash_test.eq(s, told.dn, ada_dn, "and reports the dn the directory returned")
    s = gdash_test.eq(s, count(told.raw), 2, "with the raw group values before normalisation")
    printed = join(told.steps, " ") + " " + told.dn + " " + join(told.raw, " ") + " " + join(told.groups, " ")
    s = gdash_test.ok(s, not contains(printed, "obviously-fake"), "and no service-account password anywhere in it")

    ' The message that would have turned G5-4 from a silent refusal into a
    ' sentence somebody could act on.
    empty = gdash_auth_ldap.explain(ctx_for(mof, { binds: one_bind(ada_dn, { ok: true }), rules: [bare_entry, group_rule] }), "ada")
    s = gdash_test.contains_text(s, join(empty.steps, " "), "memberof overlay", "a memberof strategy that resolves nothing says why")

    exit(gdash_test.report(s))
end program
