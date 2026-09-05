' Request handling, in process.
'
' gdash_app is the largest module in the product and holds every authorization
' decision. Its own file header has said since GDASH-0 that it is "kept out of
' the server block so the same logic is directly testable without a socket".
' Nothing tested it that way until now: the only coverage was bash and curl,
' asserting on substrings of whole HTML pages (findings G6-4, G6-6).
'
' Handlers take a plain `req` record and return a response record, so the
' assertions here are on the RECORD -- status, headers, cookies -- and only
' then on body content. A 403 is a number; it cannot also be a stylesheet rule.

function req_for(path, cookies, query)
    return { method: "GET", path: path, headers: {}, query: query,
             cookies: cookies, form: {}, scheme: "http", params: {} }
end function

function no_cookies()
    return {}
end function

function session_cookie(sid)
    c = {}
    c["gdash_session"] = sid
    return c
end function

' A minimal valid record. Access and groups are the only things these tests
' vary, so everything else is the smallest thing that validates.
function record_for(name, access, view_groups, edit_groups)
    r = { format: 1, name: name, datasets: {}, visuals: {}, controls: {}, params: {},
          tabs: [{ name: "T", layout: { vert: [] } }] }
    if access != "" then
        r["access"] = access
    end if
    if count(view_groups) > 0 then
        r["view_groups"] = view_groups
    end if
    if count(edit_groups) > 0 then
        r["edit_groups"] = edit_groups
    end if
    return r
end function

function viewer(authed, name, groups, admin)
    return { authed: authed, name: name, email: "", groups: groups, admin: admin, sid: "" }
end function

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_record from "../src/gdash_record.bas"
    load gdash_users from "../src/gdash_users.bas"
    load gdash_session from "../src/gdash_session.bas"
    load gdash_session_files from "../src/gdash_session_files.bas"
    load gdash_app from "../src/gdash_app.bas"

    s = gdash_test.suite("app")
    root = args[0]
    p = gdash_paths.roles(root)

    ' --- the authorization matrix, as a table ----------------------------
    '
    ' Written out long-hand, a missing row is invisible. The rule is coarse
    ' and per-dashboard (design §8), so it fits in a table and belongs in one.
    '
    ' Records:  open       access: open, no groups
    '           team       view_groups + edit_groups: analysts
    '           locked     no access, no groups -- a half-configured dashboard
    ' Viewers:  anon, member (analysts), outsider (shipping), admin
    open_rec = record_for("open", "open", [], [])
    team_rec = record_for("team", "", ["analysts"], ["analysts"])
    locked_rec = record_for("locked", "", [], [])

    anon = viewer(false, "", [], false)
    member = viewer(true, "ada", ["analysts"], false)
    outsider = viewer(true, "bo", ["shipping"], false)
    boss = viewer(true, "root_of_all", [], true)

    cases = [
        { rec: open_rec, who: anon, need: "view", want: true, why: "access: open serves anyone, signed in or not" },
        { rec: open_rec, who: outsider, need: "view", want: true, why: "including a signed-in stranger" },
        { rec: open_rec, who: anon, need: "edit", want: false, why: "but open never grants edit" },
        { rec: open_rec, who: outsider, need: "edit", want: false, why: "not even to someone who may view it" },
        { rec: open_rec, who: boss, need: "edit", want: true, why: "an admin may edit an open dashboard" },

        { rec: team_rec, who: anon, need: "view", want: false, why: "a group dashboard is closed to anonymous" },
        { rec: team_rec, who: member, need: "view", want: true, why: "and open to its group" },
        { rec: team_rec, who: outsider, need: "view", want: false, why: "and closed to another group" },
        { rec: team_rec, who: boss, need: "view", want: true, why: "an admin needs no group" },
        { rec: team_rec, who: member, need: "edit", want: true, why: "its edit group may edit" },
        { rec: team_rec, who: outsider, need: "edit", want: false, why: "others may not" },
        { rec: team_rec, who: anon, need: "edit", want: false, why: "and anonymous certainly may not" },

        { rec: locked_rec, who: anon, need: "view", want: false, why: "a record naming nothing serves nobody" },
        { rec: locked_rec, who: member, need: "view", want: false, why: "not even a signed-in viewer" },
        { rec: locked_rec, who: outsider, need: "view", want: false, why: "half-configured fails closed" },
        { rec: locked_rec, who: boss, need: "view", want: true, why: "leaving it to administrators only" },
        { rec: locked_rec, who: boss, need: "edit", want: true, why: "who may also edit it" },
        { rec: locked_rec, who: member, need: "edit", want: false, why: "and nobody else can" }
    ]

    i = 0
    while i < count(cases)
        c = cases[i]
        got = gdash_app.allowed(c.rec, c.who, c.need)
        s = gdash_test.eq(s, got, c.want, c.why)
        i += 1
    end while

    ' An editor can always see what they may change; the reverse is not true,
    ' and `edit` never falls back to `view`.
    view_only = record_for("v", "", ["analysts"], ["managers"])
    s = gdash_test.ok(s, gdash_app.allowed(view_only, member, "view"), "a view group may view")
    s = gdash_test.ok(s, not gdash_app.allowed(view_only, member, "edit"), "and may not edit")
    edit_only = record_for("e", "", [], ["analysts"])
    s = gdash_test.ok(s, gdash_app.allowed(edit_only, member, "view"), "an editor may view what they may change")

    ' --- the same rules over a real request ------------------------------
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "open"))
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "team"))
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "locked"))
    wrote = write_record(gdash_paths.record_file(p, "open"), open_rec)
    wrote = write_record(gdash_paths.record_file(p, "team"), team_rec)
    wrote = write_record(gdash_paths.record_file(p, "locked"), locked_rec)

    db = gdash_users.upsert(gdash_users.empty(), "ada", password_hash("fake-analyst-pw"), "ada@example.invalid", ["analysts"], false, false)
    db = gdash_users.upsert(db, "bo", password_hash("fake-outsider-pw"), "bo@example.invalid", ["shipping"], false, false)
    db = gdash_users.upsert(db, "root_of_all", password_hash("fake-boss-pw"), "", [], true, false)
    saved = gdash_users.save(p, db)
    s = gdash_test.ok(s, saved, "the user file is written")

    store = gdash_session_files.store(p)
    ada_sid = gdash_session.create(store, "ada", epoch()).session.id
    bo_sid = gdash_session.create(store, "bo", epoch()).session.id
    boss_sid = gdash_session.create(store, "root_of_all", epoch()).session.id

    s = gdash_test.eq(s, status_of(gdash_app.dashboard_page(req_for("/d/open", no_cookies(), {}), "open")), 200, "an open dashboard renders for a stranger")
    s = gdash_test.eq(s, status_of(gdash_app.dashboard_page(req_for("/d/team", session_cookie(ada_sid), {}), "team")), 200, "a group dashboard renders for its group")

    ' THE DISCLOSURE RULE. On an intranet the existence of a dashboard called
    ' `layoffs-q3` is itself information, so an anonymous viewer is told it
    ' does not exist. A signed-in viewer who merely lacks the group gets 403:
    ' for them the secret is their access, not the dashboard's existence.
    s = gdash_test.eq(s, status_of(gdash_app.dashboard_page(req_for("/d/team", no_cookies(), {}), "team")), 404, "an anonymous viewer is not told the dashboard exists")
    s = gdash_test.eq(s, status_of(gdash_app.dashboard_page(req_for("/d/team", session_cookie(bo_sid), {}), "team")), 403, "a signed-in non-member is told they lack access")
    s = gdash_test.eq(s, status_of(gdash_app.dashboard_page(req_for("/d/locked", session_cookie(ada_sid), {}), "locked")), 403, "a half-configured dashboard is refused")
    s = gdash_test.eq(s, status_of(gdash_app.dashboard_page(req_for("/d/locked", session_cookie(boss_sid), {}), "locked")), 200, "and served to an administrator")
    s = gdash_test.eq(s, status_of(gdash_app.dashboard_page(req_for("/d/ghost", session_cookie(ada_sid), {}), "ghost")), 404, "a dashboard that does not exist is 404 for everyone")

    ' A name that tries to leave the dashboards directory is refused before
    ' anything reads a file.
    s = gdash_test.eq(s, status_of(gdash_app.dashboard_page(req_for("/d/x", no_cookies(), {}), "../../etc/users")), 400, "a dashboard name containing a slash is refused")

    ' --- a session that stops resolving ----------------------------------
    db2 = gdash_users.upsert(db, "ada", "", "ada@example.invalid", ["analysts"], false, true)
    saved = gdash_users.save(p, db2)
    s = gdash_test.eq(s, status_of(gdash_app.dashboard_page(req_for("/d/team", session_cookie(ada_sid), {}), "team")), 404, "disabling an account ends its session at once")
    s = gdash_test.ok(s, is_unknown(store.get(store.ctx, ada_sid)), "and the session file is gone")
    restored = gdash_users.save(p, db)

    ' --- whoami is the identity, never the preview ------------------------
    who = gdash_app.whoami(req_for("/whoami", session_cookie(bo_sid), {}))
    s = gdash_test.contains_text(s, string(who.body), "\"user\":\"bo\"", "whoami names the signed-in user")
    s = gdash_test.contains_text(s, string(who.body), "shipping", "with their groups")
    anon_who = gdash_app.whoami(req_for("/whoami", no_cookies(), {}))
    s = gdash_test.contains_text(s, string(anon_who.body), "\"authenticated\":false", "and reports an absent session as anonymous")

    ' --- login refusals ----------------------------------------------------
    bad = gdash_app.login({ method: "POST", path: "/login", headers: {}, query: {},
                            cookies: session_cookie(bo_sid), scheme: "http", params: {},
                            form: { user: "ada", pass: "wrong" } })
    s = gdash_test.eq(s, status_of(bad), 400, "a login without a CSRF token is refused before the password is read")

    exit(gdash_test.report(s))
end program

function status_of(response)
    return default(response["status"], 200)
end function

function write_record(path, rec)
    f {file} = path
    write(f, encode(rec))
    return true
end function
