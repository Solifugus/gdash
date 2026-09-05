' gdash — the LDAP provider.
'
' The policy half of what design §7 calls "the gBASIC layer above": DN
' construction, escaping, group strategy, attribute normalisation. The wire is
' the platform's native `ldap` module and nothing here reimplements any of it.
'
' `load ldap` is inside the functions that speak to a directory rather than at
' the library level, so that a gbasic built without libldap still loads gdash
' -- and fails only when a directory login is actually attempted, guarded, with
' a message, rather than at startup.
'
' TWO RULES RUN THROUGH EVERY FUNCTION HERE.
'
' 1. THE USERNAME IS ATTACKER-CONTROLLED TEXT going into a DN or a search
'    filter. It is escaped per RFC 4514 (DN) and RFC 4515 (filter) on every
'    path, with no exception for "it came from our own form". An unescaped
'    `*)(uid=*` in a filter is an authentication bypass, not a formatting bug.
'
' 2. ATTRIBUTES ARE ALWAYS NAMED. A search with no `attributes` list returns
'    everything the bind identity may read, which bound as a directory admin
'    includes `userPassword` (finding G5-6). No attribute record is logged,
'    audited or put in a dashboard record.
'
' And one rule about failure: `ldap.connect` and `ldap.bind` are BOTH guarded
' everywhere. A raise inside a request handler kills the worker (PLAT-WEB,
' let-it-crash), so a directory problem must never become a worker problem.

library gdash_auth_ldap

    load gdash_auth from "gdash_auth.bas"

    ' --- escaping (pure; these are the hermetic tests) --------------------

    ' Both escapes are ONE HAND-WRITTEN PASS rather than a chain of `replace`
    ' calls, so that an escape introduced by one rule is never re-escaped by
    ' the next. Order-dependence is the classic way to get this wrong, and a
    ' single scan cannot have it.
    '
    ' They were originally hand-written for a second reason that no longer
    ' applies: `replace`, `trim`, `join`, `split` and `ends_with` used to read
    ' their arguments as C strings, so a NUL -- the one character RFC 4515 and
    ' RFC 4514 most oblige us to escape -- silently truncated the value on its
    ' way through the obvious implementation (finding G5-9). That is fixed in
    ' the platform as of gbasic `36cb538`, on both the haystack and the needle.
    ' The scans stay because they are correct, tested and cheap here, not
    ' because the builtins cannot be trusted; a NUL round-trip is asserted in
    ' the suite either way.
    '
    ' `mid` is O(i) on codepoint-indexed strings, which makes a per-character
    ' scan quadratic. That is fine at the length of a username and a DN and
    ' would not be at the length of a document; the callers are bounded by a
    ' login form and by what a directory returned.

    ' RFC 4515 §3. One pass, so that an escape introduced here is never
    ' escaped again by a later one.
    function escape_filter(s)
        out = ""
        i = 0
        n = len(s)
        while i < n
            c = mid(s, i, 1)
            k = code(c)
            if k = 0 then
                out = out + "\\00"
            else if c = "\\" then
                out = out + "\\5c"
            else if c = "*" then
                out = out + "\\2a"
            else if c = "(" then
                out = out + "\\28"
            else if c = ")" then
                out = out + "\\29"
            else
                out = out + c
            end if
            i += 1
        end while
        return out
    end function

    ' RFC 4514 §2.4: the characters that end or split an RDN, plus the
    ' positional cases -- a leading space or '#', and a trailing space -- which
    ' are structural rather than literal.
    function escape_dn(s)
        out = ""
        i = 0
        n = len(s)
        while i < n
            c = mid(s, i, 1)
            k = code(c)
            if k = 0 then
                out = out + "\\00"
            else if c = "\\" then
                out = out + "\\5c"
            else if c = "," then
                out = out + "\\2c"
            else if c = "+" then
                out = out + "\\2b"
            else if c = chr(34) then
                out = out + "\\22"
            else if c = "<" then
                out = out + "\\3c"
            else if c = ">" then
                out = out + "\\3e"
            else if c = ";" then
                out = out + "\\3b"
            else if c = "=" then
                out = out + "\\3d"
            else
                out = out + c
            end if
            i += 1
        end while
        if len(out) > 0 then
            head = mid(out, 0, 1)
            if head = " " then
                out = "\\20" + mid(out, 1, len(out) - 1)
            else if head = "#" then
                out = "\\23" + mid(out, 1, len(out) - 1)
            end if
        end if
        if len(out) > 0 then
            tail = mid(out, len(out) - 1, 1)
            if tail = " " then
                out = mid(out, 0, len(out) - 1) + "\\20"
            end if
        end if
        return out
    end function

    ' The inverse, for reading a name back out of a DN the directory gave us.
    ' Both spellings RFC 4514 allows: `\XX` by hex and `\c` for the character
    ' itself.
    function unescape_dn(s)
        out = ""
        i = 0
        n = len(s)
        while i < n
            c = mid(s, i, 1)
            if c = "\\" and i + 1 < n then
                nxt = mid(s, i + 1, 1)
                pair = ""
                if i + 2 <= n - 1 then
                    pair = mid(s, i + 1, 2)
                end if
                on error goto next
                decoded = ""
                if len(pair) = 2 then
                    decoded = hex_decode(lower(pair))
                end if
                if error then
                    decoded = ""
                end if
                if decoded != "" then
                    out = out + decoded
                    i += 3
                else
                    out = out + nxt
                    i += 2
                end if
            else
                out = out + c
                i += 1
            end if
        end while
        return out
    end function

    ' The leftmost RDN's VALUE, unescaped: `cn=analysts,ou=groups,dc=x` is
    ' `analysts`. A comma or an equals inside the value is escaped by whoever
    ' wrote the DN, so the scan stops at the first UNESCAPED one.
    function rdn_of(dn)
        s = string(dn)
        n = len(s)
        cut = n
        i = 0
        while i < n
            c = mid(s, i, 1)
            if c = "\\" then
                i += 2
            else
                if c = "," or c = "+" then
                    cut = i
                    i = n
                else
                    i += 1
                end if
            end if
        end while
        head = mid(s, 0, cut)
        eq = -1
        j = 0
        while j < len(head)
            c = mid(head, j, 1)
            if c = "\\" then
                j += 2
            else
                if c = "=" and eq < 0 then
                    eq = j
                    j = len(head)
                else
                    j += 1
                end if
            end if
        end while
        if eq < 0 then
            return unescape_dn(head)
        end if
        return unescape_dn(mid(head, eq + 1, len(head) - eq - 1))
    end function

    ' --- attributes (every value is an array, even a single one: G5-3) -----

    function values_of(entry, name)
        attrs = entry["attributes"]
        if is_unknown(attrs) then
            return []
        end if
        v = attrs[name]
        if is_unknown(v) then
            return []
        end if
        if type(v) != "array" then
            return [string(v)]
        end if
        return v
    end function

    function first_of(entry, name)
        v = values_of(entry, name)
        if count(v) = 0 then
            return ""
        end if
        return string(v[0])
    end function

    ' Group DNs (or names) to the plain names a record's `view_groups` uses.
    function group_names(values, style)
        out = []
        i = 0
        while i < count(values)
            one = string(values[i])
            if style = "dn" then
                out = concat(out, [one])
            else
                out = concat(out, [rdn_of(one)])
            end if
            i += 1
        end while
        return out
    end function

    ' --- configuration readers -------------------------------------------

    function group_strategy(cfg)
        return string(default(cfg["group_strategy"], ""))
    end function

    function group_style(cfg)
        return string(default(cfg["group_names"], "rdn"))
    end function

    function mail_attr(cfg)
        return string(default(cfg["email_attribute"], "mail"))
    end function

    function name_attr(cfg)
        return string(default(cfg["name_attribute"], "cn"))
    end function

    function member_attr(cfg)
        return string(default(cfg["group_attribute"], "memberOf"))
    end function

    function group_name_attr(cfg)
        return string(default(cfg["group_name_attribute"], "cn"))
    end function

    function admin_groups(cfg)
        g = cfg["admin_groups"]
        if is_unknown(g) then
            return []
        end if
        return g
    end function

    ' Empty `admin_groups` means NO directory user is an administrator, which
    ' is the fail-closed answer and leaves the local admin as the only one. An
    ' operator who wants directory admins types a group name.
    function is_admin(cfg, groups)
        want = admin_groups(cfg)
        i = 0
        while i < count(groups)
            if contains(want, groups[i]) then
                return true
            end if
            i += 1
        end while
        return false
    end function

    ' Template mode. `{user}` is the only placeholder and it is DN-escaped.
    function dn_from_template(cfg, username)
        return replace(string(cfg["user_dn_template"]), "{user}", escape_dn(username))
    end function

    function user_filter(cfg, username)
        us = cfg["user_search"]
        return replace(string(us["filter"]), "{user}", escape_filter(username))
    end function

    function group_filter(cfg, dn)
        return replace(string(default(cfg["group_filter"], "(member={dn})")), "{dn}", escape_filter(dn))
    end function

    ' --- the wire ---------------------------------------------------------

    function connect_config(cfg)
        c = { host: string(cfg["host"]), security: string(cfg["security"]) }
        if not is_unknown(cfg["port"]) then
            c["port"] = cfg["port"]
        end if
        if cfg["verify"] = false then
            c["verify"] = false
        end if
        if trim(string(default(cfg["ca_file"], ""))) != "" then
            c["ca_file"] = string(cfg["ca_file"])
        end if
        return c
    end function

    ' THE SEAM. Everything below this line that touches a directory goes
    ' through a record of function values, exactly as gdash_session takes a
    ' store and gdash_auth takes a provider:
    '
    '   wire = { ctx,
    '            open:   fn(ctx, connect_config) -> { ok, conn, reason },
    '            bind:   fn(ctx, conn, dn, password) -> { ok, reason },
    '            search: fn(ctx, conn, spec) -> { ok, entries },
    '            close:  fn(ctx, conn) -> bool }
    '
    ' The live implementation is the four `wire_*` functions; a scripted
    ' directory in tests/ is the other. Before this existed, roughly four
    ' hundred lines of authentication policy ran ONLY under GDASH_LDAP_TEST=1,
    ' which is to say: not at all, from a clean checkout with no container.
    '
    ' The seam buys more than a coverage number. A healthy directory will not
    ' return a search that succeeds with zero entries, an entry whose `dn`
    ' disagrees with the filter that found it, or `server_error` on the third
    ' call and not the first. Those branches exist precisely because a real
    ' directory might misbehave, and only a scripted one can make it.

    function wire_open(ctx, config)
        on error goto next
        load ldap
        if error then
            return { ok: false, conn: unknown, reason: "no_ldap" }
        end if
        conn = ldap.connect(config)
        if error then
            return { ok: false, conn: unknown, reason: "server_error" }
        end if
        return { ok: true, conn: conn, reason: "" }
    end function

    function wire_bind(ctx, conn, dn, password)
        on error goto next
        load ldap
        if error then
            return { ok: false, reason: "server_error" }
        end if
        r = ldap.bind(conn, dn, password)
        if error then
            return { ok: false, reason: "server_error" }
        end if
        return { ok: r.ok, reason: string(r.reason) }
    end function

    function wire_search(ctx, conn, spec)
        on error goto next
        load ldap
        if error then
            return { ok: false, entries: [] }
        end if
        found = ldap.search(conn, spec)
        if error then
            return { ok: false, entries: [] }
        end if
        return { ok: true, entries: found }
    end function

    function wire_close(ctx, conn)
        if is_unknown(conn) then
            return false
        end if
        on error goto next
        load ldap
        if error then
            return false
        end if
        closed = ldap.close(conn)
        return true
    end function

    function live_directory()
        return { ctx: {}, open: gdash_auth_ldap.wire_open, bind: gdash_auth_ldap.wire_bind,
                 search: gdash_auth_ldap.wire_search, close: gdash_auth_ldap.wire_close }
    end function

    ' What a provider carries as its ctx: the profile, and the directory it
    ' speaks to. gBASIC has function references and not closures, so both
    ' travel as arguments.
    function directory_ctx(cfg, wire)
        return { cfg: cfg, wire: wire }
    end function

    ' Open a connection and, when a service account is configured, bind as it.
    ' Returns { ok, conn, message, reason }. Guards everything: none of it may
    ' reach a request handler as a raise.
    function open_service(wire, cfg)
        opened = wire.open(wire.ctx, connect_config(cfg))
        if not opened.ok then
            if opened.reason = "no_ldap" then
                return { ok: false, conn: unknown, message: "this build has no ldap support", reason: "server_error" }
            end if
            return { ok: false, conn: unknown, message: "the directory refused the connection settings", reason: "server_error" }
        end if
        conn = opened.conn
        dn = trim(string(default(cfg["bind_dn"], "")))
        if dn = "" then
            ' Anonymous. Many directories allow a read-only anonymous search;
            ' those that do not will simply return nothing, which the caller
            ' reads as "cannot be sure" rather than as "no such user".
            return { ok: true, conn: conn, message: "", reason: "" }
        end if
        r = wire.bind(wire.ctx, conn, dn, string(default(cfg["bind_password"], "")))
        if not r.ok then
            closed = wire.close(wire.ctx, conn)
            ' The service account's own password being wrong is an operator's
            ' problem, never a viewer's: it is reported as unavailable, not as
            ' a bad password.
            return { ok: false, conn: unknown, message: "the service account could not bind: " + string(r.reason), reason: string(r.reason) }
        end if
        return { ok: true, conn: conn, message: "", reason: "" }
    end function

    function search_via(wire, conn, spec)
        return wire.search(wire.ctx, conn, spec)
    end function

    function close_via(wire, conn)
        return wire.close(wire.ctx, conn)
    end function

    ' Bind as the user, on a connection of their own.
    function bind_as(wire, cfg, dn, password)
        opened = wire.open(wire.ctx, connect_config(cfg))
        if not opened.ok then
            return { ok: false, reason: "server_error", conn: unknown }
        end if
        r = wire.bind(wire.ctx, opened.conn, dn, password)
        return { ok: r.ok, reason: string(r.reason), conn: opened.conn }
    end function

    ' Find the user's entry with a service (or anonymous) connection.
    ' Returns { ok, dn, entry, certain }. `certain` is false when the search
    ' could not be trusted to be authoritative -- no service account and
    ' nothing came back -- because "the directory would not tell me" and "there
    ' is no such user" are two facts and must not be one branch.
    function find_user(wire, cfg, conn, username, extra)
        us = cfg["user_search"]
        want = [mail_attr(cfg), name_attr(cfg)]
        i = 0
        while i < count(extra)
            want = concat(want, [extra[i]])
            i += 1
        end while
        spec = { base: string(us["base"]),
                 scope: string(default(us["scope"], "sub")),
                 filter: user_filter(cfg, username),
                 attributes: want,
                 limit: 2 }
        got = search_via(wire, conn, spec)
        certain = trim(string(default(cfg["bind_dn"], ""))) != ""
        if not got.ok then
            return { ok: false, dn: "", entry: {}, certain: false }
        end if
        if count(got.entries) = 0 then
            return { ok: false, dn: "", entry: {}, certain: certain }
        end if
        return { ok: true, dn: string(got.entries[0].dn), entry: got.entries[0], certain: true }
    end function

    ' The two strategies, named in configuration with no default (G5-4).
    function groups_for(wire, cfg, conn, dn, entry)
        style = group_style(cfg)
        strategy = group_strategy(cfg)
        if strategy = "memberof" then
            raw = values_of(entry, member_attr(cfg))
            if count(raw) = 0 then
                ' Re-read the entry directly: in template mode there was no
                ' user search, so nothing has read the attribute yet.
                got = search_via(wire, conn, { base: dn, scope: "base", filter: "(objectClass=*)", attributes: [member_attr(cfg)], limit: 1 })
                if got.ok and count(got.entries) > 0 then
                    raw = values_of(got.entries[0], member_attr(cfg))
                end if
            end if
            return group_names(raw, style)
        end if
        if strategy = "search" then
            got = search_via(wire, conn, { base: string(cfg["group_base"]),
                                         scope: string(default(cfg["group_scope"], "sub")),
                                         filter: group_filter(cfg, dn),
                                         attributes: [group_name_attr(cfg)] })
            if not got.ok then
                return []
            end if
            out = []
            i = 0
            while i < count(got.entries)
                if style = "dn" then
                    out = concat(out, [string(got.entries[i].dn)])
                else
                    nm = first_of(got.entries[i], group_name_attr(cfg))
                    if nm = "" then
                        nm = rdn_of(string(got.entries[i].dn))
                    end if
                    out = concat(out, [nm])
                end if
                i += 1
            end while
            return out
        end if
        ' Unreachable through a validated configuration; empty rather than a
        ' guess, because a guess here is exactly the G5-4 failure.
        return []
    end function

    ' Bind as the user. Returns the ldap module's own outcome, guarded.
    function bind_as(wire, cfg, dn, password)
        on error goto next
        load ldap
        if error then
            return { ok: false, reason: "server_error", conn: unknown }
        end if
        conn = ldap.connect(connect_config(cfg))
        if error then
            return { ok: false, reason: "server_error", conn: unknown }
        end if
        r = ldap.bind(conn, dn, password)
        if error then
            closed = ldap.close(conn)
            return { ok: false, reason: "server_error", conn: unknown }
        end if
        return { ok: r.ok, reason: string(r.reason), conn: conn }
    end function

    ' --- the provider ------------------------------------------------------

    function ldap_authenticate(ctx, username, password)
        ' ctx carries the profile and the directory it speaks to
        ' (directory_ctx). A provider built by ldap_provider always has both.
        cfg = ctx["cfg"]
        wire = ctx["wire"]
        if trim(username) = "" or password = "" then
            ' Not sent to the directory: an empty password is an unauthenticated
            ' bind, which the directory answers with SUCCESS. The module refuses
            ' it too; refusing it here as well means it never travels.
            return gdash_auth.miss()
        end if

        dn = ""
        entry = {}
        svc = unknown
        if trim(string(default(cfg["user_dn_template"], ""))) != "" then
            dn = dn_from_template(cfg, username)
        else
            opened = open_service(wire, cfg)
            if not opened.ok then
                return gdash_auth.unreachable(opened.message)
            end if
            svc = opened.conn
            got = find_user(wire, cfg, svc, username, [member_attr(cfg)])
            if not got.ok then
                closed = close_via(wire, svc)
                if not got.certain then
                    return gdash_auth.unreachable("the directory could not be searched")
                end if
                ' A service account looked and there is no such user. Not this
                ' provider's username.
                return gdash_auth.miss()
            end if
            dn = got.dn
            entry = got.entry
        end if

        bound = bind_as(wire, cfg, dn, password)
        if not bound.ok then
            closed = close_via(wire, bound.conn)
            closed = close_via(wire, svc)
            if gdash_auth.operational(bound.reason) then
                return gdash_auth.unreachable("the directory is not answering (" + bound.reason + ")")
            end if
            ' invalid_credentials, or empty_password from the module. In
            ' template mode this is also the only answer a nonexistent DN
            ' produces -- deliberately, since no enumeration oracle is the
            ' point -- so `known` is true and the chain stops here.
            return gdash_auth.reject()
        end if

        ' Groups are read with the service account when there is one, and with
        ' the user's own connection otherwise.
        reader = svc
        if is_unknown(reader) then
            reader = bound.conn
        end if
        groups = groups_for(wire, cfg, reader, dn, entry)
        email = first_of(entry, mail_attr(cfg))
        shown = first_of(entry, name_attr(cfg))
        if email = "" or shown = "" then
            got = search_via(wire, reader, { base: dn, scope: "base", filter: "(objectClass=*)", attributes: [mail_attr(cfg), name_attr(cfg)], limit: 1 })
            if got.ok and count(got.entries) > 0 then
                if email = "" then
                    email = first_of(got.entries[0], mail_attr(cfg))
                end if
                if shown = "" then
                    shown = first_of(got.entries[0], name_attr(cfg))
                end if
            end if
        end if
        closed = close_via(wire, bound.conn)
        closed = close_via(wire, svc)
        return gdash_auth.accept(gdash_auth.make_identity(username, email, groups, is_admin(cfg, groups)))
    end function

    ' Re-resolving without a password, for revalidation and for `auth check`.
    ' Needs a readable directory; when it cannot be sure, it says so rather
    ' than reporting the user gone -- a directory outage that logs everyone out
    ' turns a directory problem into a total outage (brief §2.6).
    function ldap_identity(ctx, username)
        ' ctx carries the profile and the directory it speaks to
        ' (directory_ctx). A provider built by ldap_provider always has both.
        cfg = ctx["cfg"]
        wire = ctx["wire"]
        if trim(username) = "" then
            return gdash_auth.miss()
        end if
        opened = open_service(wire, cfg)
        if not opened.ok then
            return gdash_auth.unreachable(opened.message)
        end if
        conn = opened.conn
        dn = ""
        entry = {}
        certain = trim(string(default(cfg["bind_dn"], ""))) != ""
        if trim(string(default(cfg["user_dn_template"], ""))) != "" then
            dn = dn_from_template(cfg, username)
            got = search_via(wire, conn, { base: dn, scope: "base", filter: "(objectClass=*)", attributes: [mail_attr(cfg), name_attr(cfg), member_attr(cfg)], limit: 1 })
            if not got.ok or count(got.entries) = 0 then
                closed = close_via(wire, conn)
                if not certain then
                    return gdash_auth.unreachable("the directory could not be read without a service account")
                end if
                return gdash_auth.miss()
            end if
            entry = got.entries[0]
        else
            got = find_user(wire, cfg, conn, username, [member_attr(cfg)])
            if not got.ok then
                closed = close_via(wire, conn)
                if not got.certain then
                    return gdash_auth.unreachable("the directory could not be searched")
                end if
                return gdash_auth.miss()
            end if
            dn = got.dn
            entry = got.entry
        end if
        groups = groups_for(wire, cfg, conn, dn, entry)
        identity = gdash_auth.make_identity(username, first_of(entry, mail_attr(cfg)), groups, is_admin(cfg, groups))
        closed = close_via(wire, conn)
        return gdash_auth.accept(identity)
    end function

    ' The seam, assembled. A record of function values plus the context they
    ' need, because gBASIC has function references and not closures.
    function ldap_provider(cfg, wire)
        every = 300
        if not is_unknown(cfg["revalidate"]) then
            every = cfg["revalidate"]
        end if
        return { kind: "ldap", name: string(default(cfg["name"], "directory")), ctx: directory_ctx(cfg, wire),
                 authenticate: gdash_auth_ldap.ldap_authenticate,
                 identity: gdash_auth_ldap.ldap_identity,
                 revalidate: every }
    end function

    ' --- diagnosis (`gdash auth check`) ------------------------------------
    '
    ' Without this, the first evidence that a `group_strategy` is wrong is a
    ' dashboard refusing everyone -- which is finding G5-4 happening to an
    ' operator instead of to gdash. It reports every step it took and what came
    ' back, INCLUDING the raw attribute values before normalisation, because
    ' "memberOf came back empty" and "memberOf came back with DNs I parsed
    ' wrongly" are different problems with the same symptom.
    '
    ' It prints no password. The service account's credential is used and never
    ' echoed, and no attribute record beyond the three gdash asked for is read
    ' at all (finding G5-6).
    function explain(ctx, username)
        ' ctx carries the profile and the directory it speaks to
        ' (directory_ctx). A provider built by ldap_provider always has both.
        cfg = ctx["cfg"]
        wire = ctx["wire"]
        steps = ["connect " + string(cfg["host"]) + " security=" + string(cfg["security"])]
        opened = open_service(wire, cfg)
        if not opened.ok then
            return { ok: false, steps: concat(steps, ["FAILED: " + opened.message]), dn: "", raw: [], groups: [], email: "" }
        end if
        if trim(string(default(cfg["bind_dn"], ""))) = "" then
            steps = concat(steps, ["bound anonymously (no bind_dn configured)"])
        else
            steps = concat(steps, ["bound as the service account " + string(cfg["bind_dn"])])
        end if
        conn = opened.conn
        dn = ""
        entry = {}
        if trim(string(default(cfg["user_dn_template"], ""))) != "" then
            dn = dn_from_template(cfg, username)
            steps = concat(steps, ["user DN from template: " + dn])
            got = search_via(wire, conn, { base: dn, scope: "base", filter: "(objectClass=*)", attributes: [mail_attr(cfg), name_attr(cfg), member_attr(cfg)], limit: 1 })
            if got.ok and count(got.entries) > 0 then
                entry = got.entries[0]
                steps = concat(steps, ["read that entry"])
            else
                steps = concat(steps, ["could not read that entry -- with no service account this is expected, and it is also what a wrong template looks like"])
            end if
        else
            f = user_filter(cfg, username)
            steps = concat(steps, ["user search in " + string(cfg["user_search"]["base"]) + " with " + f])
            got = find_user(wire, cfg, conn, username, [member_attr(cfg)])
            if not got.ok then
                closed = close_via(wire, conn)
                return { ok: false, steps: concat(steps, ["FAILED: no entry matched"]), dn: "", raw: [], groups: [], email: "" }
            end if
            dn = got.dn
            entry = got.entry
            steps = concat(steps, ["found " + dn])
        end if

        strategy = group_strategy(cfg)
        raw = []
        if strategy = "memberof" then
            steps = concat(steps, ["group_strategy memberof: reading " + member_attr(cfg)])
            raw = values_of(entry, member_attr(cfg))
            if count(raw) = 0 then
                got = search_via(wire, conn, { base: dn, scope: "base", filter: "(objectClass=*)", attributes: [member_attr(cfg)], limit: 1 })
                if got.ok and count(got.entries) > 0 then
                    raw = values_of(got.entries[0], member_attr(cfg))
                end if
            end if
            if count(raw) = 0 then
                steps = concat(steps, ["the attribute is EMPTY. Stock OpenLDAP does not populate memberOf without the memberof overlay; try group_strategy 'search' instead"])
            end if
        else
            steps = concat(steps, ["group_strategy search in " + string(default(cfg["group_base"], "")) + " with " + group_filter(cfg, dn)])
            got = search_via(wire, conn, { base: string(default(cfg["group_base"], "")), scope: string(default(cfg["group_scope"], "sub")), filter: group_filter(cfg, dn), attributes: [group_name_attr(cfg)] })
            if got.ok then
                i = 0
                while i < count(got.entries)
                    raw = concat(raw, [string(got.entries[i].dn)])
                    i += 1
                end while
            end if
            if count(raw) = 0 then
                steps = concat(steps, ["nothing matched. Check group_base, and whether the groups use 'member' or 'uniqueMember'"])
            end if
        end if
        groups = groups_for(wire, cfg, conn, dn, entry)
        closed = close_via(wire, conn)
        return { ok: true, steps: steps, dn: dn, raw: raw, groups: groups, email: first_of(entry, mail_attr(cfg)) }
    end function

end library
