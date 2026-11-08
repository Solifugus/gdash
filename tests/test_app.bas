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
        got = gdash_app.allowed(c.rec, c.who, c.need, true)
        s = gdash_test.eq(s, got, c.want, c.why)
        i += 1
    end while

    ' Where the root may not publish to the world (a tenant, by default:
    ' GDASH-16), `access: open` opens nothing. The groups still apply, so the
    ' same record is an admins-only one rather than a broken one.
    s = gdash_test.ok(s, not gdash_app.allowed(open_rec, anon, "view", false), "where open access is not permitted, an open record does not serve anonymous")
    s = gdash_test.ok(s, not gdash_app.allowed(open_rec, outsider, "view", false), "nor a signed-in stranger")
    s = gdash_test.ok(s, gdash_app.allowed(open_rec, boss, "view", false), "and an admin still sees it")

    ' An editor can always see what they may change; the reverse is not true,
    ' and `edit` never falls back to `view`.
    view_only = record_for("v", "", ["analysts"], ["managers"])
    s = gdash_test.ok(s, gdash_app.allowed(view_only, member, "view", true), "a view group may view")
    s = gdash_test.ok(s, not gdash_app.allowed(view_only, member, "edit", true), "and may not edit")
    edit_only = record_for("e", "", [], ["analysts"])
    s = gdash_test.ok(s, gdash_app.allowed(edit_only, member, "view", true), "an editor may view what they may change")

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

    ' --- the shim, asserted where it is produced -------------------------
    '
    ' Not by fetching a page: the shim is on every page whatever the dashboard
    ' contains, so a page assertion about it passes for the wrong reason and
    ' the assertion audit refuses it -- correctly, even though the furniture is
    ' exactly what was meant.
    shim = gdash_app._shim(3, "0007.json", {})
    s = gdash_test.contains_text(s, shim, "function gdashPublish(", "there is one publish path")
    s = gdash_test.contains_text(s, shim, "gdashPublish(el.getAttribute('data-param'),el.value)", "a slicer goes through it")
    s = gdash_test.contains_text(s, shim, "closest('[data-publishes]')", "and so does a click on a keyed mark")
    s = gdash_test.contains_text(s, shim, "addEventListener('click'", "the listener is delegated, so it survives a fragment being replaced")
    s = gdash_test.eq(s, count(split(shim, "location.pathname+'/params'")) - 1, 1, "and there is exactly ONE place a param is posted from")

    ' --- the index lists only what the viewer may open --------------------
    '
    ' A LIST OF NAMES IS A DISCLOSURE. Design §8 refuses an anonymous viewer
    ' with 404 rather than 403 precisely because "layoffs-q3 exists" is itself
    ' information, so an index that named a dashboard somebody cannot open
    ' would undo that in one line of HTML. The three records here are the
    ' three cases: open to anyone, shared with a group, and admin-only.
    ' A NEW session: ada's first one was destroyed above, by the assertion
    ' that disabling an account ends its session at once.
    ada_again = gdash_session.create(store, "ada", epoch()).session.id
    anon_index = string(gdash_app.index_page(req_for("/", no_cookies(), {})).body)
    s = gdash_test.contains_text(s, anon_index, "/d/open", "a stranger sees the dashboard that opted into open access")
    s = gdash_test.ok(s, not contains(anon_index, "/d/team"), "and NOT one shared with a group they are not in")
    s = gdash_test.ok(s, not contains(anon_index, "/d/locked"), "nor one with no access at all")

    ada_index = string(gdash_app.index_page(req_for("/", session_cookie(ada_again), {})).body)
    s = gdash_test.contains_text(s, ada_index, "/d/team", "a member sees the dashboard shared with their group")
    s = gdash_test.contains_text(s, ada_index, "/d/open", "and the open one as well")
    s = gdash_test.ok(s, not contains(ada_index, "/d/locked"), "and still not the one reserved to administrators")

    bo_index = string(gdash_app.index_page(req_for("/", session_cookie(bo_sid), {})).body)
    s = gdash_test.ok(s, not contains(bo_index, "/d/team"), "signing in does not by itself reveal a group's dashboard")

    ' A record that does not load is ABSENT, not named with an error beside
    ' it. The operator sees it in `gdash list`; a viewer can do nothing about
    ' it, and being unparseable is not a reason to disclose that it exists.
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "corrupt"))
    broke {file} = gdash_paths.record_file(p, "corrupt")
    write(broke, "{ not json")
    broken_index = string(gdash_app.index_page(req_for("/", no_cookies(), {})).body)
    s = gdash_test.ok(s, not contains(broken_index, "corrupt"), "a record that does not load is absent from the index, not named")
    s = gdash_test.contains_text(s, broken_index, "/d/open", "and the dashboards beside it still list")

    boss_index = string(gdash_app.index_page(req_for("/", session_cookie(boss_sid), {})).body)
    s = gdash_test.contains_text(s, boss_index, "/d/locked", "an administrator sees the one nobody else may open")

    ' The wording is identical whether nothing exists or nothing is shared:
    ' "3 dashboards exist, none for you" is the disclosure this page avoids.
    s = gdash_test.contains_text(s, gdash_app._index_empty_text(true), "shared with you", "a signed-in viewer with nothing is told nothing is shared")
    s = gdash_test.ok(s, not contains(gdash_app._index_empty_text(true), "0"), "and is not told how many they cannot see")

    ' --- the poll that replaced the held stream (GDASH-11) ----------------
    '
    ' The baseline is embedded at render time, not learned on the first poll.
    ' A refresh landing in the second between the render and the first poll
    ' would otherwise be invisible until the poll after that.
    s = gdash_test.contains_text(s, shim, "var gdashV=\"3\"", "the shim carries the version it was rendered at")
    s = gdash_test.contains_text(s, shim, "gdashP=\"0007.json\"", "and the publish pointer it was rendered at")
    s = gdash_test.contains_text(s, shim, "location.pathname+'/version'", "and polls for both")
    s = gdash_test.ok(s, not contains(shim, "EventSource"), "and holds no stream open, which is the worker it used to hold")
    ' The two directions are not the same action: a data refresh reloads,
    ' a publish only offers (design §7).
    s = gdash_test.contains_text(s, shim, "if(String(d.v)!==gdashV){location.reload()", "a moved version reloads")
    s = gdash_test.contains_text(s, shim, "if(String(d.pub)!==gdashP){gdashP=String(d.pub);gdashNotice()}", "a moved pointer only offers")

    ' A value on its way into a <script> element. JSON quoting alone does not
    ' escape angle brackets, and `</script>` inside a JS string literal ends
    ' the element regardless of the quoting around it.
    hostile = gdash_app._shim(1, "</script><script>alert(1)</script>", {})
    s = gdash_test.ok(s, not contains(hostile, "</script>"), "no embedded value can close the script element")
    s = gdash_test.contains_text(s, hostile, "\\u003c/script", "the bracket is spelled as an escape instead")

    ' The page's own params are a viewer's query string on its way into the
    ' same <script> (GDASH-19), and get the same treatment.
    hostp = gdash_app._shim(1, "0001.json", { region: "</script><script>alert(1)</script>" })
    s = gdash_test.ok(s, not contains(hostp, "</script>"), "no param value can close the script element")
    s = gdash_test.contains_text(s, hostp, "var gdashParams=", "the page holds its params")

    ' --- the version endpoint is as closed as the page --------------------
    s = gdash_test.eq(s, status_of(gdash_app.version_of(req_for("/d/open/version", no_cookies(), {}), "open")), 200, "an open dashboard reports its version to a stranger")
    s = gdash_test.contains_text(s, string(gdash_app.version_of(req_for("/d/open/version", no_cookies(), {}), "open").body), "\"v\":", "and the report names the dataset version")
    s = gdash_test.eq(s, status_of(gdash_app.version_of(req_for("/d/team/version", no_cookies(), {}), "team")), 404, "a dashboard an anonymous viewer may not open does not leak its version")
    s = gdash_test.eq(s, status_of(gdash_app.version_of(req_for("/d/team/version", session_cookie(bo_sid), {}), "team")), 403, "nor to a signed-in viewer outside its groups")
    s = gdash_test.eq(s, status_of(gdash_app.version_of(req_for("/d/team/version", session_cookie(ada_again), {}), "team")), 200, "and reports it to the group that may see it")
    s = gdash_test.eq(s, status_of(gdash_app.version_of(req_for("/d/x/version", no_cookies(), {}), "../../etc/users")), 400, "a version request naming a path is refused like any other")

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
