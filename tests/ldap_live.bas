' The LDAP provider against a REAL directory. Opt-in; never part of the
' hermetic suite.
'
'   scripts/ldap_test_directory.sh up
'   eval "$(scripts/ldap_test_directory.sh env)"
'   tests/run_ldap.sh
'
' Every password here is obviously fake and lives in a throwaway container's
' seed file, which is committed beside it. Nothing here reaches a real
' directory, and nothing here is a credential anywhere else.
'
' The hermetic suite tests the policy -- escaping, DN construction, the chain,
' group normalisation -- and needs no directory at all. This tests only what a
' directory can prove, which is that the platform's module and gdash's use of
' it agree with a server neither of them wrote.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_auth from "../src/gdash_auth.bas"
    load gdash_auth_ldap from "../src/gdash_auth_ldap.bas"

    s = gdash_test.suite("ldap-live")

    ' The provider's ctx is the profile plus the directory it speaks to. Here
    ' that directory is the real one; the hermetic suite passes a scripted one
    ' to exactly the same functions.
    wire = gdash_auth_ldap.live_directory()

    host = default(env("GDASH_LDAP_HOST"), "127.0.0.1")
    port = number(default(env("GDASH_LDAP_PORT"), "3890"))
    base = default(env("GDASH_LDAP_BASE"), "dc=example,dc=invalid")
    svc_dn = default(env("GDASH_LDAP_BIND_DN"), "")
    svc_pw = default(env("GDASH_LDAP_BIND_PW"), "")
    people = "ou=people," + base
    groups = "ou=groups," + base

    ' --- template mode, group_strategy search -----------------------------
    tpl = { kind: "ldap", name: "directory", host: host, port: port, security: "plain",
            user_dn_template: "uid={user}," + people,
            group_strategy: "search", group_base: groups,
            bind_dn: svc_dn, bind_password: svc_pw }

    good = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(tpl, wire), "ada", "fake-directory-pw")
    s = gdash_test.ok(s, good.ok, "the right password binds against a real directory")
    s = gdash_test.ok(s, good.known, "and the provider says it knows the user")
    s = gdash_test.ok(s, good.available, "with the directory available")
    s = gdash_test.eq(s, good.identity.name, "ada", "yielding the identity")
    s = gdash_test.eq(s, good.identity.email, "ada@example.invalid", "with the mail attribute")
    s = gdash_test.eq(s, join(sort(good.identity.groups), ","), "analysts,finance", "and the groups a member= search finds")
    s = gdash_test.ok(s, not good.identity.admin, "and no admin it was not given")

    wrong = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(tpl, wire), "ada", "not-the-password")
    s = gdash_test.ok(s, not wrong.ok, "a wrong password is refused")
    s = gdash_test.ok(s, wrong.known, "and it is this provider's user")
    s = gdash_test.ok(s, wrong.available, "with no suggestion the directory is down")
    s = gdash_test.eq(s, wrong.message, gdash_auth.refusal(), "with the one refusal")

    ' A DN that does not exist answers invalid_credentials, deliberately: no
    ' enumeration oracle (G5-3). In template mode that makes it indistinguishable
    ' from a wrong password, which is why `known` is true either way.
    ghost = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(tpl, wire), "nobodyatall", "whatever")
    s = gdash_test.ok(s, not ghost.ok, "a user who does not exist is refused")
    s = gdash_test.eq(s, ghost.message, gdash_auth.refusal(), "with the same message as a wrong password")

    ' Refused locally: an empty password is an unauthenticated bind, which the
    ' directory answers with SUCCESS. It never travels.
    blank = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(tpl, wire), "ada", "")
    s = gdash_test.ok(s, not blank.ok, "an empty password cannot sign anyone in")
    s = gdash_test.ok(s, not blank.known, "and is not even sent")

    ' Template mode with NO service account: the simple deployment, where the
    ' only operation is the user's own bind and groups are read over the
    ' connection that bind produced.
    bare = { kind: "ldap", name: "directory", host: host, port: port, security: "plain",
             user_dn_template: "uid={user}," + people,
             group_strategy: "search", group_base: groups }
    alone = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(bare, wire), "ada", "fake-directory-pw")
    s = gdash_test.ok(s, alone.ok, "template mode needs no service account to authenticate")
    s = gdash_test.eq(s, join(sort(alone.identity.groups), ","), "analysts,finance", "and reads groups over the user's own connection")

    ' --- memberOf against stock OpenLDAP: the finding, preserved as a test --
    '
    ' G5-4. The overlay is off by default, so `memberof` resolves ZERO groups
    ' from exactly the directory `search` resolves two from. Zero groups is a
    ' legitimate answer, so it fails silently -- which is why the strategy is
    ' named in configuration with no default.
    mof = { kind: "ldap", name: "directory", host: host, port: port, security: "plain",
            user_dn_template: "uid={user}," + people,
            group_strategy: "memberof",
            bind_dn: svc_dn, bind_password: svc_pw }
    quiet = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(mof, wire), "ada", "fake-directory-pw")
    s = gdash_test.ok(s, quiet.ok, "the memberof strategy still authenticates")
    s = gdash_test.eq(s, count(quiet.identity.groups), 0, "and resolves NO groups from a directory with no memberof overlay")

    ' --- user_search mode --------------------------------------------------
    srch = { kind: "ldap", name: "directory", host: host, port: port, security: "plain",
             user_search: { base: people, scope: "sub", filter: "(uid={user})" },
             group_strategy: "search", group_base: groups,
             bind_dn: svc_dn, bind_password: svc_pw }
    found = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(srch, wire), "bo", "another-fake-pw")
    s = gdash_test.ok(s, found.ok, "a service-account search finds the user and binds as them")
    s = gdash_test.eq(s, join(found.identity.groups, ","), "shipping", "with their own groups")

    ' With a service account, "no such user" is a fact rather than a guess, so
    ' the chain is told to move on rather than to stop.
    absent = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(srch, wire), "nobodyatall", "whatever")
    s = gdash_test.ok(s, not absent.ok, "a search that matches nothing does not authenticate")
    s = gdash_test.ok(s, not absent.known, "and reports the username as not this provider's")
    s = gdash_test.ok(s, absent.available, "which is not the same as the directory being down")

    ' The injection that escaping exists to stop, against a real server.
    nasty = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(srch, wire), "*)(uid=*", "fake-directory-pw")
    s = gdash_test.ok(s, not nasty.ok, "a filter-injection username matches nothing")
    s = gdash_test.ok(s, not nasty.known, "rather than matching the first entry in the tree")

    ' --- identity without a password ---------------------------------------
    who = gdash_auth_ldap.ldap_identity(gdash_auth_ldap.directory_ctx(srch, wire), "ada")
    s = gdash_test.ok(s, who.ok, "an identity re-resolves without a password")
    s = gdash_test.eq(s, join(sort(who.identity.groups), ","), "analysts,finance", "with current groups")
    s = gdash_test.eq(s, who.identity.email, "ada@example.invalid", "and the mail attribute")
    left = gdash_auth_ldap.ldap_identity(gdash_auth_ldap.directory_ctx(srch, wire), "nobodyatall")
    s = gdash_test.ok(s, not left.ok, "a user who is not there does not re-resolve")
    s = gdash_test.ok(s, left.available, "and with a service account that is a real absence, not an outage")

    ' --- admin comes from a group ------------------------------------------
    boss = { kind: "ldap", name: "directory", host: host, port: port, security: "plain",
             user_dn_template: "uid={user}," + people,
             group_strategy: "search", group_base: groups,
             admin_groups: ["finance"],
             bind_dn: svc_dn, bind_password: svc_pw }
    promoted = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(boss, wire), "ada", "fake-directory-pw")
    s = gdash_test.ok(s, promoted.identity.admin, "a named admin group makes an administrator")
    demoted = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(boss, wire), "bo", "another-fake-pw")
    s = gdash_test.ok(s, not demoted.identity.admin, "and only for its members")

    ' --- a directory that is not there -------------------------------------
    '
    ' The distinction the whole design turns on: this must never look like a
    ' wrong password.
    dead = { kind: "ldap", name: "directory", host: host, port: 1, security: "plain",
             user_dn_template: "uid={user}," + people,
             group_strategy: "search", group_base: groups }
    outage = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(dead, wire), "ada", "fake-directory-pw")
    s = gdash_test.ok(s, not outage.ok, "an unreachable directory cannot sign anyone in")
    s = gdash_test.ok(s, not outage.available, "and reports itself unavailable")
    s = gdash_test.ok(s, not outage.known, "rather than claiming the credential was wrong")

    ' StartTLS to a plaintext port: a failure, never a silent downgrade.
    downgrade = { kind: "ldap", name: "directory", host: host, port: port, security: "starttls",
                  user_dn_template: "uid={user}," + people,
                  group_strategy: "search", group_base: groups }
    tls = gdash_auth_ldap.ldap_authenticate(gdash_auth_ldap.directory_ctx(downgrade, wire), "ada", "fake-directory-pw")
    s = gdash_test.ok(s, not tls.ok, "StartTLS against a plaintext server does not bind")
    s = gdash_test.ok(s, not tls.available, "and is an operator's problem, not a viewer's")

    ' --- the chain, with the real directory as its second link -------------
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_authcfg from "../src/gdash_authcfg.bas"
    p = gdash_paths.roles(args[0])
    chain = gdash_authcfg.chain_from(p, { format: 1, directory: tpl })
    s = gdash_test.eq(s, count(chain), 2, "the chain is local and then the directory")
    s = gdash_test.eq(s, chain[0].name, "local", "with local first, always")
    reached = gdash_auth.sign_in(chain, "ada", "fake-directory-pw")
    s = gdash_test.ok(s, reached.ok, "a directory user signs in through the chain")
    s = gdash_test.eq(s, reached.provider, "directory", "and it is the directory that answered")

    ' --- the diagnostic prints no password ---------------------------------
    told = gdash_auth_ldap.explain(gdash_auth_ldap.directory_ctx(tpl, wire), "ada")
    s = gdash_test.ok(s, told.ok, "auth check resolves the user")
    s = gdash_test.eq(s, told.dn, "uid=ada," + people, "and reports the DN it built")
    s = gdash_test.eq(s, count(told.raw), 2, "with the raw group values before normalisation")
    printed = join(told.steps, " ") + " " + told.dn + " " + join(told.raw, " ") + " " + join(told.groups, " ")
    s = gdash_test.ok(s, not contains(printed, svc_pw), "and no service-account password anywhere in the output")
    s = gdash_test.ok(s, not contains(printed, "fake-directory-pw"), "nor any user password")
    s = gdash_test.ok(s, not contains(printed, "userPassword"), "and no attribute gdash did not name")

    ' The message that would have saved finding G5-4 from being discovered by
    ' a dashboard refusing everyone.
    empty = gdash_auth_ldap.explain(gdash_auth_ldap.directory_ctx(mof, wire), "ada")
    s = gdash_test.contains_text(s, join(empty.steps, " "), "memberof overlay", "a memberof strategy that resolves nothing says why")

    exit(gdash_test.report(s))
end program
