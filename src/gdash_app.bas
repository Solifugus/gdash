' gdash — request handling.
'
' Kept out of the server block so the same logic is directly testable without
' a socket, and so each handler stays one line.

library gdash_app

    load crypto
    load gdash_paths from "gdash_paths.bas"
    load gdash_record from "gdash_record.bas"
    load gdash_store from "gdash_store.bas"
    load gdash_render from "gdash_render.bas"
    load gdash_format from "gdash_format.bas"
    load gdash_refresh from "gdash_refresh.bas"
    load gdash_sched from "gdash_sched.bas"
    load gdash_publish from "gdash_publish.bas"
    load gdash_diff from "gdash_diff.bas"
    load gdash_session from "gdash_session.bas"
    load gdash_session_files from "gdash_session_files.bas"
    load gdash_users from "gdash_users.bas"
    load gdash_auth from "gdash_auth.bas"
    load gdash_authcfg from "gdash_authcfg.bas"
    load gdash_theme from "gdash_theme.bas"
    load gdash_throttle from "gdash_throttle.bas"
    load gdash_audit from "gdash_audit.bas"
    load gdash_ask from "gdash_ask.bas"
    load gdash_nlq from "gdash_nlq.bas"

    function _root_of(req)
        return default(env("GDASH_ROOT"), "")
    end function

    function paths_for(req)
        return gdash_paths.roles(_root_of(req))
    end function

    function _html(body)
        return { body: body, headers: { "content-type": "text/html; charset=utf-8" } }
    end function

    function _json(value)
        return { body: encode(value), headers: { "content-type": "application/json" } }
    end function

    function _refuse(code, message)
        return { status: code, body: encode({ error: message }), headers: { "content-type": "application/json" } }
    end function

    function _store(p)
        return gdash_session_files.store(p)
    end function

    ' Server-level, generated at first use. A fixed secret in the source would
    ' make every deployment's CSRF tokens forgeable by anyone who read the
    ' source, and a per-worker secret would make them forgeable by nobody --
    ' including the worker that has to check them.
    '
    ' THAT LAST CLAUSE IS WHY THIS TAKES A LOCK (finding G6-3). Under
    ' `workers: N` the first request after an install can arrive at several
    ' workers at once, each finding no secret and each minting its own. The
    ' creation is therefore serialized with the same advisory lock idiom
    ' gdash_refresh uses, and the state is re-read inside the lock -- so the
    ' second worker through finds the first one's secret rather than replacing
    ' it. The write itself is temp + atomic_replace, like every other durable
    ' write in gdash; it was the one that was not.
    function secret_of(p)
        got = _read_secret(gdash_paths.secret_file(p))
        if got != "" then
            return got
        end if
        made = gdash_paths.ensure_dir(p.config_dir)
        path = gdash_paths.secret_file(p)
        lockpath = path + ".lock"
        on error goto next
        lf {file} = lockpath
        if not gdash_paths.path_exists(lockpath) then
            write(lf, "")
        end if
        if error then
            ' No lock is available. Minting unserialized is still better than
            ' refusing to serve, and the failure it risks is a token that reads
            ' as expired -- which fails closed.
            return _mint_secret(path)
        end if
        out = ""
        with lock(lf)
            again = _read_secret(path)
            if again != "" then
                out = again
            else
                out = _mint_secret(path)
            end if
        end with
        return out
    end function

    function _read_secret(path)
        if not gdash_paths.path_exists(path) then
            return ""
        end if
        on error goto next
        f {file} = path
        got = trim(read(f))
        if error then
            return ""
        end if
        return got
    end function

    ' Restricted BEFORE it becomes the real file, as gdash_users.save does: a
    ' window in which the secret is world-readable is a window.
    function _mint_secret(path)
        fresh = crypto.random_token(32)
        tmp = path + ".tmp"
        on error goto next
        nf {file} = tmp
        write(nf, fresh)
        if error then
            return fresh
        end if
        locked = gdash_paths.restrict(tmp)
        atomic_replace(tmp, path)
        if error then
            return fresh
        end if
        locked = gdash_paths.restrict(path)
        return fresh
    end function

    ' HTTPS only. Design §6 expects intranet deployments where TLS is
    ' recommended rather than required, so a hardcoded Secure would silently
    ' break login on exactly the deployments the design describes.
    function _secure(req)
        return string(default(req["scheme"], "http")) = "https"
    end function

    function _sid(req)
        c = req["cookies"]
        if is_unknown(c) then
            return ""
        end if
        return string(default(c["gdash_session"], ""))
    end function

    ' An anonymous viewer may still hold a session: the login form needs one
    ' so its CSRF token has something to be bound to. Carrying the id here is
    ' what lets "not signed in" and "has no session at all" stay one concept
    ' to every caller while still being different facts.
    function anonymous_with(sid)
        return { authed: false, name: "", email: "", groups: [], admin: false, sid: sid }
    end function

    function anonymous()
        return anonymous_with("")
    end function

    ' Who is asking. An expired session, a forged id and no cookie at all are
    ' one answer -- anonymous -- because to everything downstream they are the
    ' same fact.
    function viewer_of(req, p)
        sid = _sid(req)
        if sid = "" then
            return anonymous()
        end if
        now = epoch()
        got = gdash_session.active(_store(p), sid, now, gdash_session.limits())
        if not got.ok then
            return anonymous()
        end if
        holder = string(got.session.user)
        if holder = "" then
            ' A pre-login session: real, unprivileged, and NOT to be destroyed.
            ' Destroying it here would take the login form's CSRF token with
            ' it and make signing in impossible.
            return anonymous_with(sid)
        end if
        remembered = gdash_session.data_of(got.session)
        chain = gdash_authcfg.providers(p)
        every = gdash_auth.revalidate_of(chain, string(default(remembered["provider"], "local")))

        ' Local accounts revalidate on every request -- reading users.json is
        ' cheap, and a disabled account stops working immediately, which is
        ' GDASH-4's behaviour unchanged. A directory cannot be asked that
        ' often, so its identity is materialized into the session and
        ' re-resolved on an interval. Group changes therefore take effect
        ' within `revalidate` seconds, and that is written down rather than
        ' discovered (brief §2.6).
        if not gdash_auth.revalidation_due(remembered["checked"], now, every) then
            return _viewer_from(remembered["identity"], sid)
        end if

        who = gdash_auth.whois(chain, holder)
        if who.unavailable then
            ' A directory outage must not log everyone out: that turns a
            ' directory problem into a total outage. The session stands until
            ' its ordinary absolute and idle limits, and the outage is audited
            ' -- at most once per interval per session, which is what keeps
            ' this from becoming a log flood.
            logged = gdash_audit.event(p, "identity.unavailable", { user: holder })
            if not is_unknown(remembered["identity"]) then
                return _viewer_from(remembered["identity"], sid)
            end if
            return anonymous_with(sid)
        end if
        if not who.ok then
            ' The account was removed or disabled while the session lived, so
            ' the session goes with it.
            dropped = gdash_session.destroy(_store(p), sid)
            return anonymous()
        end if
        if every > 0 then
            ' Only worth a write when something is actually being cached. With
            ' `revalidate: 0` the identity is re-resolved next request anyway,
            ' and a store write per request would make reading a dashboard a
            ' write-heavy operation.
            stored = gdash_session.assign(_store(p), sid, holder, _remember(who.provider, who.identity, now), now)
        end if
        return _viewer_from(who.identity, sid)
    end function

    function _remember(provider, identity, now)
        return { provider: provider, identity: identity, checked: now }
    end function

    ' The viewer record every handler downstream reads, built from a resolved
    ' identity. One place, so a cached identity and a freshly resolved one
    ' cannot drift into two shapes.
    function _viewer_from(identity, sid)
        if is_unknown(identity) then
            return anonymous_with(sid)
        end if
        g = identity["groups"]
        if is_unknown(g) then
            g = []
        end if
        return { authed: true, name: string(identity["name"]), email: string(default(identity["email"], "")), groups: g, admin: identity["admin"] = true, sid: sid }
    end function

    function identity_of(v)
        if not v.authed then
            return unknown
        end if
        return { name: v.name, email: v.email, groups: v.groups }
    end function

    function _in_any(groups, allowed)
        if is_unknown(allowed) then
            return false
        end if
        i = 0
        while i < count(groups)
            if contains(allowed, groups[i]) then
                return true
            end if
            i += 1
        end while
        return false
    end function

    ' Coarse and per-dashboard (design §8). `need` is "view" or "edit".
    '
    ' Fails closed in every direction: a record naming no groups and no
    ' `access` is admins-only, an unauthenticated viewer gets nothing that is
    ' not explicitly open, and `edit` never falls back to `view`.
    function allowed(rec, v, need)
        if need = "view" and rec["access"] = "open" then
            return true
        end if
        if not v.authed then
            return false
        end if
        if v.admin then
            return true
        end if
        if need = "edit" then
            return _in_any(v.groups, rec["edit_groups"])
        end if
        ' An editor can always see what they may change; saying otherwise
        ' would be a rule nobody could configure their way out of.
        return _in_any(v.groups, rec["view_groups"]) or _in_any(v.groups, rec["edit_groups"])
    end function

    ' access is a per-dashboard opt-in and everything fails closed (design §8).
    ' A record with no `access` key is refused: a half-configured server must
    ' not serve. This build implements no identity, so `open` is the only mode
    ' it can honour -- and saying so is what keeps the default closed rather
    ' than leaving a window where "no auth yet" means "open to all".
    function _access_ok(rec)
        return rec["access"] = "open"
    end function

    ' The snapshot this viewer is pinned to, from their cookie. Empty when
    ' they have none, which is every first visit.
    function _pin_of(req)
        c = req["cookies"]
        if is_unknown(c) then
            return ""
        end if
        return string(default(c["gdash_pin"], ""))
    end function

    ' Scoped to this dashboard's own path, so one cookie name serves every
    ' dashboard without a map. No Max-Age: it is a SESSION cookie, and design
    ' §7 pins a snapshot for a session -- closing the browser is what ends it.
    function _pin_cookie(name, leaf)
        return "gdash_pin=" + leaf + "; Path=/d/" + name + "; HttpOnly; SameSite=Lax"
    end function

    ' Returns { ok, rec, p, mode, snapshot, pin_was, response } -- response set
    ' only when refusing. A published dashboard serves the snapshot this
    ' viewer pinned at session open, or `current` if they have not pinned one;
    ' an unpublished dashboard serves the draft.
    function _load_dashboard(req, name, need)
        p = paths_for(req)
        if contains(name, "/") then
            return { ok: false, rec: {}, p: p, mode: "draft", snapshot: "", pin_was: "", viewer: anonymous(), response: _refuse(400, "bad dashboard name") }
        end if
        pin = _pin_of(req)
        pub = gdash_paths.pinned(p, name, pin)
        v = viewer_of(req, p)
        loaded = gdash_record.load_file(pub.record_file)
        if not loaded.ok then
            if contains(join(loaded.errors, "|"), "not found") then
                return { ok: false, rec: {}, p: p, mode: pub.mode, snapshot: pub.snapshot, pin_was: pin, viewer: v, response: _refuse(404, "no such dashboard: " + name) }
            end if
            return { ok: false, rec: {}, p: p, mode: pub.mode, snapshot: pub.snapshot, pin_was: pin, viewer: v, response: _refuse(500, "dashboard is invalid: " + join(loaded.errors, "; ")) }
        end if
        if not allowed(loaded.record, v, need) then
            logged = gdash_audit.event(p, "access.denied", { dashboard: name, user: v.name, need: need })
            ' 404 for an anonymous viewer, not 403: on an intranet, the
            ' existence of a dashboard called "layoffs-q3" is itself
            ' information. An authenticated viewer who simply lacks the group
            ' gets 403, because for them the dashboard's existence is not the
            ' secret -- their access to it is.
            if not v.authed then
                return { ok: false, rec: {}, p: p, mode: pub.mode, snapshot: pub.snapshot, pin_was: pin, viewer: v, response: _refuse(404, "no such dashboard: " + name) }
            end if
            return { ok: false, rec: {}, p: p, mode: pub.mode, snapshot: pub.snapshot, pin_was: pin, viewer: v, response: _refuse(403, "you are not in a group this dashboard is shared with") }
        end if
        return { ok: true, rec: loaded.record, p: p, mode: pub.mode, snapshot: pub.snapshot, pin_was: pin, viewer: v, response: {} }
    end function

    ' Every OTHER dataset of this dashboard that exists on disk, so a visual
    ' query may name it. Unqualified table names resolve across attached
    ' schemas (finding G2-2), which is why a cross-dataset join needs no
    ' syntax in the record and no prefix in the SQL.
    function _attach_for(p, name, mode, rec, primary)
        out = {}
        names = keys(rec["datasets"])
        i = 0
        while i < count(names)
            if names[i] != primary then
                path = gdash_paths.dataset_db(p, name, mode, names[i])
                if gdash_paths.path_exists(path) then
                    out[names[i]] = path
                end if
            end if
            i += 1
        end while
        return out
    end function

    function _visual_fragment(p, name, mode, rec, vis_name, values, theme)
        v = rec["visuals"][vis_name]
        db = gdash_paths.dataset_db(p, name, mode, v["dataset"])
        if not gdash_paths.path_exists(db) then
            return "<div class=" + chr(34) + "gdash-empty" + chr(34) + ">No data yet -- this dataset has never refreshed.</div>"
        end if
        attach = _attach_for(p, name, mode, rec, v["dataset"])
        res = gdash_store.select_rows(db, v["sql"], values, gdash_render.exact_columns(v), attach)
        if not res.ok then
            return "<div class=" + chr(34) + "gdash-error" + chr(34) + ">query failed: " + res.message + "</div>"
        end if
        return gdash_render.render_visual(vis_name, v, res.rows, db, attach, theme)
    end function

    function _control_fragment(p, name, mode, rec, ctl_name, values)
        c = rec["controls"][ctl_name]
        opts = []
        if not is_unknown(c["sql"]) then
            db = gdash_paths.dataset_db(p, name, mode, c["dataset"])
            if gdash_paths.path_exists(db) then
                res = gdash_store.select_rows(db, c["sql"], values, [], _attach_for(p, name, mode, rec, c["dataset"]))
                if res.ok then
                    i = 0
                    while i < count(res.rows)
                        row = res.rows[i]
                        ks = keys(row)
                        opts = concat(opts, [row[ks[0]]])
                        i += 1
                    end while
                end if
            end if
        end if
        return gdash_render.render_control(ctl_name, c, opts, values[c["param"]])
    end function

    function _space_css(sp)
        if sp = "between" then
            return "space-between"
        end if
        if sp = "around" then
            return "space-around"
        end if
        if sp = "evenly" then
            return "space-evenly"
        end if
        if sp = "start" then
            return "flex-start"
        end if
        if sp = "end" then
            return "flex-end"
        end if
        if sp = "center" then
            return "center"
        end if
        return ""
    end function

    ' A child with a weight flexes; a child without one takes natural size
    ' (design §2). That is flex-grow versus flex:0 0 auto, which is exactly
    ' the distinction the record is making.
    function _child_style(node)
        w = node["weight"]
        if is_unknown(w) then
            return "flex:0 0 auto"
        end if
        return "flex:" + string(w) + " 1 0"
    end function

    function _layout(p, name, mode, rec, node, values, theme)
        if not is_unknown(node["vert"]) then
            return _container(p, name, mode, rec, node, node["vert"], values, "gdash-vert", theme)
        end if
        if not is_unknown(node["horiz"]) then
            return _container(p, name, mode, rec, node, node["horiz"], values, "gdash-horiz", theme)
        end if
        if not is_unknown(node["visual"]) then
            vn = node["visual"]
            return "<div class=" + chr(34) + "gdash-cell" + chr(34) + " style=" + chr(34) + _child_style(node) + chr(34) + " data-visual=" + chr(34) + vn + chr(34) + ">" + _visual_fragment(p, name, mode, rec, vn, values, theme) + "</div>"
        end if
        if not is_unknown(node["control"]) then
            return "<div class=" + chr(34) + "gdash-cell" + chr(34) + " style=" + chr(34) + _child_style(node) + chr(34) + ">" + _control_fragment(p, name, mode, rec, node["control"], values) + "</div>"
        end if
        return ""
    end function

    function _container(p, name, mode, rec, node, kids, values, cls, theme)
        out = []
        i = 0
        while i < count(kids)
            out = concat(out, [_layout(p, name, mode, rec, kids[i], values, theme)])
            i += 1
        end while

        style = _child_style(node)
        gp = node["gap"]
        if not is_unknown(gp) then
            style = style + ";gap:" + string(gp) + "px"
        end if
        sp = node["space"]
        if not is_unknown(sp) then
            css = _space_css(sp)
            ' `space` is emitted even when validation warned it is dead: the
            ' warning tells the author it will do nothing, and silently
            ' dropping it would make the rendered page disagree with the
            ' record.
            if css != "" then
                style = style + ";justify-content:" + css
            end if
        end if
        return "<div class=" + chr(34) + cls + chr(34) + " style=" + chr(34) + style + chr(34) + ">" + join(out, "") + "</div>"
    end function

    ' Shared with the CLI's `list`, so the two cannot drift (gdash_format.when).
    function _when(at)
        return gdash_format.when(at)
    end function

    ' One line per dataset, not one line for the dashboard. With two datasets
    ' a single "data as of" is a statement about whichever one the code
    ' happened to look at, and it stops being true the moment they diverge --
    ' which is exactly when a viewer most needs it to be true.
    '
    ' A failed refresh is surfaced here too. Stale-but-coherent is only a
    ' virtue if the viewer is told the data is stale; otherwise it is just a
    ' dashboard quietly showing last week.
    function _status_block(p, name, mode, rec)
        ds = keys(rec["datasets"])
        rows = []
        i = 0
        while i < count(ds)
            st = gdash_sched.read_state(gdash_paths.dataset_state(p, name, mode, ds[i]))
            line = gdash_render.html_escape(ds[i]) + ": data as of " + gdash_render.html_escape(_when(st.last_success))
            cls = "gdash-stale-ok"
            ' A published record can be rolled back to a version whose dataset
            ' asks a different question than the one that produced the file on
            ' disk. Saying so is the whole point: the data is not merely old.
            if gdash_sched.definition_stale(rec["datasets"][ds[i]], st) then
                cls = "gdash-stale-bad"
                line = line + " — the dataset definition changed since this was fetched"
            end if
            if st.last_error != "" then
                cls = "gdash-stale-bad"
                line = line + " — last refresh failed: " + gdash_render.html_escape(st.last_error)
            end if
            rows = concat(rows, ["<span class=" + chr(34) + cls + chr(34) + ">" + line + "</span>"])
            i += 1
        end while
        return join(rows, "")
    end function

    ' The page-open side of the `on_open` policy. It files a REQUEST and
    ' returns; it does not fetch. The whole point of the two-tier model
    ' (design §3) is that the expensive fetch stays off the request path, and
    ' fetching inline here would pin a worker for exactly as long as the
    ' source is slow. The scheduler performs it; SSE tells the open tabs.
    function _request_opens(p, name, mode, rec)
        if mode != "published" then
            return 0
        end if
        ds = keys(rec["datasets"])
        now = epoch()
        i = 0
        while i < count(ds)
            statepath = gdash_paths.dataset_state(p, name, mode, ds[i])
            st = gdash_sched.read_state(statepath)
            if gdash_sched.should_request(rec["datasets"][ds[i]], st, now) then
                wrote = gdash_sched.write_state(statepath, gdash_sched.with_request(st, now))
            end if
            i += 1
        end while
        return 0
    end function

    ' A value on its way into a <script> block. JSON quotes it; the two angle
    ' brackets are then spelled as escapes, because JSON does not escape them
    ' and `</script>` inside a string literal ends the element whatever the
    ' quoting says.
    function _js_literal(s)
        return replace(replace(encode(string(s)), "<", "\\u003c"), ">", "\\u003e")
    end function

    ' `v` and `pub` are the values as of THIS render, embedded rather than
    ' learned on the first poll: a refresh that lands in the second between
    ' rendering the page and the browser's first poll would otherwise be
    ' invisible until the next one after that.
    function _shim(v, pub)
        q = chr(34)
        js = ""
        ' ONE publish path, two ways in. A slicer and a click on a bar mean the
        ' same thing -- "filter by this value" -- and routing them through one
        ' function is what keeps a click from becoming a second, subtly
        ' different way to change a param.
        js = js + "function gdashPublish(name,value){"
        js = js + "var b={};b[name]=value;"
        js = js + "fetch(location.pathname+'/params',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})"
        js = js + ".then(function(r){return r.json()}).then(function(d){"
        js = js + "for(var k in d.fragments){var c=document.querySelector('[data-visual='+JSON.stringify(k)+']');if(c){c.innerHTML=d.fragments[k]}}"
        js = js + "});}"
        js = js + "function gdashParam(el){gdashPublish(el.getAttribute('data-param'),el.value);}"
        ' A click on a data mark inside a chart that opted in. Delegated, so it
        ' keeps working after a fragment is replaced -- which is exactly what
        ' publishing a param does to the visuals that bind it.
        js = js + "document.addEventListener('click',function(ev){"
        js = js + "var t=ev.target;if(!t||!t.closest){return}"
        js = js + "var m=t.closest('[data-key]');if(!m){return}"
        js = js + "var h=m.closest('[data-publishes]');if(!h){return}"
        js = js + "gdashPublish(h.getAttribute('data-publishes'),m.getAttribute('data-key'));"
        js = js + "});"
        js = js + "function gdashTab(b){var i=b.getAttribute('data-tab');"
        js = js + "var ts=document.querySelectorAll('.gdash-tab');for(var j=0;j<ts.length;j++){ts[j].classList.toggle('gdash-tab-active',ts[j]===b)}"
        js = js + "var ps=document.querySelectorAll('.gdash-pane');for(var k=0;k<ps.length;k++){ps[k].hidden=(ps[k].getAttribute('data-pane')!==i)}}"
        js = js + "function gdashNotice(){var b=document.getElementById('gdash-notice');if(b){b.hidden=false}}"
        ' Global events, polled by the browser rather than by a worker held
        ' open on its behalf (GDASH-11). The facts are the same two files;
        ' what changed is which process does the waiting. One open dashboard
        ' used to occupy a worker for as long as the tab was open, which at
        ' the default worker count meant gdash answered nothing else.
        '
        ' Five seconds because this notice is not urgent: a refresh that a
        ' viewer learns about five seconds late costs them nothing, and the
        ' data they are looking at was already correct when it was served.
        js = js + "var gdashV=" + _js_literal(v) + ",gdashP=" + _js_literal(pub) + ";"
        js = js + "setInterval(function(){"
        js = js + "fetch(location.pathname+'/version',{headers:{'accept':'application/json'}})"
        js = js + ".then(function(r){return r.ok?r.json():null}).then(function(d){"
        js = js + "if(!d){return}"
        js = js + "if(String(d.v)!==gdashV){location.reload();return}"
        ' A NOTICE, not a reload. Yanking the page out from under a pinned
        ' viewer is the thing pinning exists to prevent (design §7): a new
        ' version arrives on the next open, or when the viewer decides.
        js = js + "if(String(d.pub)!==gdashP){gdashP=String(d.pub);gdashNotice()}"
        js = js + "});},5000);"
        return js
    end function

    function _style()
        s = ""
        s = s + ".gdash-vert{display:flex;flex-direction:column;gap:12px}"
        s = s + ".gdash-horiz{display:flex;flex-direction:row;gap:12px;align-items:flex-start}"
        s = s + ".gdash-cell{flex:1 1 auto;min-width:0}"
        s = s + "body{font-family:system-ui,sans-serif;margin:24px;color:#222}"
        s = s + ".gdash-value{border:1px solid #ddd;border-radius:8px;padding:16px}"
        s = s + ".gdash-value-title{font-size:12px;color:#666}"
        s = s + ".gdash-value-number{font-size:28px;font-variant-numeric:tabular-nums}"
        s = s + ".gdash-error{color:#a00;border:1px solid #a00;border-radius:6px;padding:8px;font-size:13px}"
        s = s + ".gdash-empty{color:#666;font-style:italic;padding:8px}"
        s = s + ".gdash-index{list-style:none;padding:0;max-width:480px}"
        s = s + ".gdash-index li{padding:10px 12px;border:1px solid #ddd;border-radius:8px;margin-bottom:8px}"
        s = s + ".gdash-index a{text-decoration:none;font-size:16px}"
        s = s + ".gdash-stale{color:#666;font-size:12px;margin-bottom:12px;display:flex;flex-wrap:wrap;gap:16px}"
        s = s + ".gdash-stale-bad{color:#a00}"
        s = s + ".gdash-login{display:flex;flex-direction:column;gap:12px;max-width:320px}"
        s = s + ".gdash-login input{padding:6px;font-size:14px;width:100%;box-sizing:border-box}"
        s = s + ".gdash-login button{padding:8px;font-size:14px;cursor:pointer}"
        s = s + ".gdash-who{float:right;font-size:12px;color:#666}"
        ' Loud on purpose. A preview that looks like the real dashboard is how
        ' somebody reports a number that was never theirs.
        ' Only marks that publish something get a pointer: a cursor that
        ' promises an interaction the chart does not have is a small lie.
        s = s + ".gdash-clickable [data-key]{cursor:pointer}"
        s = s + ".gdash-preview{clear:both;margin:8px 0;padding:6px 10px;background:#fff8e1;border:1px solid #e0c060;font-size:12px}"
        s = s + ".gdash-preview input{font-size:12px;margin-right:4px}"
        s = s + ".gdash-notice{border:1px solid #c90;background:#fffbe6;border-radius:6px;padding:10px 12px;margin-bottom:12px;font-size:13px}"
        s = s + ".gdash-tabs{display:flex;gap:4px;border-bottom:1px solid #ddd;margin-bottom:16px}"
        s = s + ".gdash-tab{border:0;background:none;padding:8px 14px;cursor:pointer;font-size:14px;color:#555;border-bottom:2px solid transparent}"
        s = s + ".gdash-tab-active{color:#111;border-bottom-color:#333;font-weight:600}"
        s = s + ".gdash-table table{border-collapse:collapse;width:100%;font-size:13px}"
        s = s + ".gdash-table th{text-align:left;border-bottom:1px solid #ccc;padding:6px 10px;color:#555;font-weight:600}"
        s = s + ".gdash-table td{border-bottom:1px solid #eee;padding:6px 10px;font-variant-numeric:tabular-nums}"
        s = s + ".gdash-table-title{font-size:12px;color:#666;margin-bottom:6px}"
        s = s + ".gdash-ask{margin:12px 0;display:flex;gap:8px;align-items:center;flex-wrap:wrap}"
        s = s + ".gdash-ask input{padding:6px;font-size:14px}"
        s = s + ".gdash-ask button{padding:6px 12px;font-size:14px;cursor:pointer}"
        s = s + ".gdash-sql{background:#f6f6f6;border:1px solid #ddd;border-radius:6px;padding:10px;font-size:13px;overflow-x:auto;white-space:pre-wrap}"
        ' The unit notes are the reason this page exists, so they are not
        ' styled like the other grey furniture around them.
        s = s + ".gdash-notes{border:1px solid #c90;background:#fffbe6;border-radius:6px;padding:8px 12px;margin:12px 0;font-size:13px}"
        s = s + ".gdash-notes ul{margin:6px 0 0 0;padding-left:20px}"
        s = s + ".gdash-preview-visual{border:1px dashed #999;border-radius:8px;padding:12px;margin:12px 0}"
        return s
    end function

    ' Who you are, and the way out. The logout form carries its own CSRF token
    ' because logging out is a state change, and a link that logs you out is a
    ' link someone else can put in an image tag.
    function _who_bar(p, v)
        q = chr(34)
        if not v.authed then
            return "<div class=" + q + "gdash-who" + q + "><a href=" + q + "/login" + q + ">Sign in</a></div>"
        end if
        tok = gdash_session.csrf_for(secret_of(p), v.sid)
        h = "<div class=" + q + "gdash-who" + q + ">" + gdash_render.html_escape(v.name) + " "
        h = h + "<form method=" + q + "post" + q + " action=" + q + "/logout" + q + " style=" + q + "display:inline" + q + ">"
        h = h + "<input type=" + q + "hidden" + q + " name=" + q + "csrf" + q + " value=" + q + tok + q + ">"
        h = h + "<button type=" + q + "submit" + q + " style=" + q + "border:0;background:none;color:#06c;cursor:pointer;font-size:12px" + q + ">sign out</button>"
        h = h + "</form></div>"
        return h
    end function

    ' --- preview-as (design §8, brief §2.7) -------------------------------
    '
    ' An editor answers "what does this look like to somebody in Shipping?"
    ' without borrowing a password. Draft only, editors only, audited -- and it
    ' substitutes the injected user_* params AND NOTHING ELSE. Authorization
    ' stays the real viewer's throughout: you cannot preview-as your way into a
    ' dashboard you may not open, and you cannot preview-as your way into being
    ' an admin. Anything else would be privilege escalation with a friendly
    ' name.
    '
    ' It lives in the session rather than in the URL so that a reload, a tab
    ' switch and a param change all keep it, and so that it cannot be handed to
    ' somebody else as a link.

    function _may_preview(got)
        return gdash_auth.preview_allowed(got.mode, allowed(got.rec, got.viewer, "edit"))
    end function

    function _preview_for(p, v, name)
        if v.sid = "" then
            return unknown
        end if
        st = _store(p)
        rec = st.get(st.ctx, v.sid)
        if is_unknown(rec) then
            return unknown
        end if
        pv = gdash_session.data_of(rec)["preview"]
        if is_unknown(pv) then
            return unknown
        end if
        ' Scoped to the dashboard it was set on: previewing one draft must not
        ' silently change what another one renders.
        if string(default(pv["dashboard"], "")) != name then
            return unknown
        end if
        return pv
    end function

    ' The identity the QUERIES see. The only thing preview-as changes.
    function _effective_identity(got, name)
        base = identity_of(got.viewer)
        if not _may_preview(got) then
            return base
        end if
        pv = _preview_for(got.p, got.viewer, name)
        if is_unknown(pv) then
            return base
        end if
        g = pv["groups"]
        if is_unknown(g) then
            g = []
        end if
        return { name: string(default(pv["name"], "")), email: string(default(pv["email"], "")), groups: g }
    end function

    function preview(req, name)
        ' need = "edit" here rather than "view": _load_dashboard already
        ' answers 404 to a stranger and 403 to a viewer who is not an editor,
        ' so the editors-only rule is enforced before this function has an
        ' opinion.
        got = _load_dashboard(req, name, "edit")
        if not got.ok then
            return got.response
        end if
        p = got.p
        v = got.viewer
        if not csrf_present(req, p, v) then
            return _refuse(400, "that form expired")
        end if
        if not _may_preview(got) then
            logged = gdash_audit.event(p, "preview.denied", { dashboard: name, user: v.name, mode: got.mode })
            return _refuse(403, "preview-as is for editors, on a draft")
        end if
        f = req["form"]
        if is_unknown(f) then
            f = {}
        end if
        st = _store(p)
        rec = st.get(st.ctx, v.sid)
        if is_unknown(rec) then
            return _refuse(400, "no session")
        end if
        data = gdash_session.data_of(rec)
        if string(default(f["clear"], "")) != "" then
            data = _drop_preview(data)
            logged = gdash_audit.event(p, "preview.ended", { dashboard: name, user: v.name })
        else
            assumed = gdash_auth.preview_identity(f["as_name"], f["as_email"], f["as_groups"])
            data["preview"] = { dashboard: name, name: assumed.name, email: assumed.email, groups: assumed.groups }
            ' The audit names WHO WAS PRETENDING, not just that somebody was.
            logged = gdash_audit.event(p, "preview.as", { dashboard: name, user: v.name, as_name: assumed.name, as_email: assumed.email, as_groups: join(assumed.groups, ",") })
        end if
        stored = gdash_session.assign(st, v.sid, string(rec["user"]), data, epoch())
        return { status: 303, headers: { "location": "/d/" + name }, body: "" }
    end function

    function _drop_preview(data)
        out = {}
        have = keys(data)
        i = 0
        while i < count(have)
            if have[i] != "preview" then
                out[have[i]] = data[have[i]]
            end if
            i += 1
        end while
        return out
    end function

    ' The editor's control, and -- when one is in force -- an unmissable band
    ' saying so. A preview that looks like the real thing is how somebody
    ' reports a number that was never theirs.
    function _preview_bar(got, name)
        if not _may_preview(got) then
            return ""
        end if
        q = chr(34)
        tok = gdash_session.csrf_for(secret_of(got.p), got.viewer.sid)
        pv = _preview_for(got.p, got.viewer, name)
        h = "<form class=" + q + "gdash-preview" + q + " method=" + q + "post" + q + " action=" + q + "/d/" + name + "/preview" + q + ">"
        h = h + "<input type=" + q + "hidden" + q + " name=" + q + "csrf" + q + " value=" + q + tok + q + ">"
        if is_unknown(pv) then
            h = h + "<span>Preview as</span> "
            h = h + "<input name=" + q + "as_name" + q + " placeholder=" + q + "name" + q + ">"
            h = h + "<input name=" + q + "as_email" + q + " placeholder=" + q + "email" + q + ">"
            h = h + "<input name=" + q + "as_groups" + q + " placeholder=" + q + "groups, comma separated" + q + ">"
            h = h + "<button type=" + q + "submit" + q + ">Preview</button>"
            h = h + "</form>"
            return h
        end if
        h = h + "<input type=" + q + "hidden" + q + " name=" + q + "clear" + q + " value=" + q + "1" + q + ">"
        h = h + "<strong>Previewing as " + gdash_render.html_escape(string(default(pv["name"], ""))) + "</strong> "
        h = h + "<span>groups: " + gdash_render.html_escape(join(pv["groups"], ", ")) + "</span> "
        h = h + "<button type=" + q + "submit" + q + ">Stop previewing</button>"
        h = h + "</form>"
        return h
    end function

    ' --- asking the data a question, in a browser --------------------------
    '
    ' The CLI does this too, and the two share everything below `gdash_ask`.
    ' What the browser adds is the part that matters most for reviewing a
    ' draft: the suggested visual is RENDERED, by the ordinary render path,
    ' running the ordinary visual query against the ordinary staged data. So
    ' the preview is not a mock of what promotion would produce -- it IS what
    ' promotion would produce, drawn before anyone commits to it.
    '
    ' ALWAYS THE DRAFT RECORD, and authorized against the DRAFT'S own edit
    ' groups. Promotion edits the draft, so the draft is what decides who may;
    ' using the served record would ask a published dashboard'"'"'s groups about an
    ' operation that does not touch it.
    function _load_draft_for_edit(req, name)
        p = paths_for(req)
        if contains(name, "/") then
            return { ok: false, rec: {}, p: p, viewer: anonymous(), response: _refuse(400, "bad dashboard name") }
        end if
        v = viewer_of(req, p)
        loaded = gdash_record.load_file(gdash_paths.record_file(p, name))
        if not loaded.ok then
            if contains(join(loaded.errors, "|"), "not found") then
                return { ok: false, rec: {}, p: p, viewer: v, response: _refuse(404, "no such dashboard: " + name) }
            end if
            return { ok: false, rec: {}, p: p, viewer: v, response: _refuse(500, "dashboard is invalid: " + join(loaded.errors, "; ")) }
        end if
        if not allowed(loaded.record, v, "edit") then
            logged = gdash_audit.event(p, "access.denied", { dashboard: name, user: v.name, need: "edit" })
            if not v.authed then
                return { ok: false, rec: {}, p: p, viewer: v, response: _refuse(404, "no such dashboard: " + name) }
            end if
            return { ok: false, rec: {}, p: p, viewer: v, response: _refuse(403, "asking a question edits the draft, and you are not an editor of it") }
        end if
        return { ok: true, rec: loaded.record, p: p, viewer: v, response: {} }
    end function

    function ask_page(req, name)
        got = _load_draft_for_edit(req, name)
        if not got.ok then
            return got.response
        end if
        return _html(_ask_html(got, name, unknown, "", ""))
    end function

    function ask_run(req, name)
        got = _load_draft_for_edit(req, name)
        if not got.ok then
            return got.response
        end if
        p = got.p
        v = got.viewer
        if not csrf_present(req, p, v) then
            return _refuse(400, "that form expired")
        end if
        f = req["form"]
        if is_unknown(f) then
            f = {}
        end if
        question = trim(string(default(f["question"], "")))
        if question = "" then
            return _html(_ask_html(got, name, unknown, "", "ask a question"))
        end if

        prof = gdash_ask.model_profile(p, "")
        if not prof.ok then
            return _html(_ask_html(got, name, unknown, question, prof.message))
        end if

        ' A model call is slow -- seconds, not milliseconds -- and it holds
        ' this worker for the whole of it. That is the same cost as a slow
        ' visual query and is bounded by the profile'"'"'s own timeout; what makes
        ' it acceptable is that only editors can reach it.
        draft = gdash_ask.ask(p, name, "draft", got.rec, question, gdash_ask.live_model(prof.profile), {})
        logged = gdash_audit.event(p, "ask", { dashboard: name, user: v.name, stage: draft.stage, question: question })

        if draft.ok then
            stored = _remember_draft(p, v, name, gdash_ask.draft_visual(draft, got.rec, draft.scaled), question)
        end if
        return _html(_ask_html(got, name, draft, question, ""))
    end function

    ' The draft rides the SESSION, not the form. A promote that carried the
    ' SQL back from the browser would accept SQL from the browser; a promote
    ' that carried only the question would spend another model call to
    ' rediscover what this one already knows. The session is a file, which is
    ' how every other piece of per-viewer state travels (design §5).
    function _remember_draft(p, v, name, vis, question)
        if v.sid = "" then
            return false
        end if
        st = _store(p)
        rec = st.get(st.ctx, v.sid)
        if is_unknown(rec) then
            return false
        end if
        data = gdash_session.data_of(rec)
        data["ask_draft"] = { dashboard: name, question: question, dataset: vis.dataset, sql: vis.sql, encoding: vis.encoding }
        stored = gdash_session.assign(st, v.sid, string(rec["user"]), data, epoch())
        return true
    end function

    function _remembered_draft(p, v, name)
        if v.sid = "" then
            return unknown
        end if
        st = _store(p)
        rec = st.get(st.ctx, v.sid)
        if is_unknown(rec) then
            return unknown
        end if
        d = gdash_session.data_of(rec)["ask_draft"]
        if is_unknown(d) or type(d) != "record" then
            return unknown
        end if
        if string(default(d["dashboard"], "")) != name then
            ' A draft belongs to the dashboard it was asked of. Promoting it
            ' into another one would put a query about one dataset into a
            ' record with different datasets entirely.
            return unknown
        end if
        return d
    end function

    function ask_promote(req, name)
        got = _load_draft_for_edit(req, name)
        if not got.ok then
            return got.response
        end if
        p = got.p
        v = got.viewer
        if not csrf_present(req, p, v) then
            return _refuse(400, "that form expired")
        end if
        f = req["form"]
        if is_unknown(f) then
            f = {}
        end if
        vid = trim(string(default(f["visual"], "")))
        held = _remembered_draft(p, v, name)
        if is_unknown(held) then
            return _html(_ask_html(got, name, unknown, "", "that draft is no longer in this session; ask again"))
        end if
        vis = { dataset: held["dataset"], sql: held["sql"], encoding: held["encoding"] }
        done = gdash_ask.promote(p, name, vid, vis)
        logged = gdash_audit.event(p, "ask.promote", { dashboard: name, user: v.name, visual: vid, ok: string(done.ok) })
        if not done.ok then
            return _html(_ask_html(got, name, unknown, string(held["question"]), done.message))
        end if
        return { status: 303, headers: { "location": "/d/" + name }, body: "" }
    end function

    ' The page. One form to ask, and -- once there is a draft -- the query,
    ' what its numbers mean, when the data was read, the rows, a real render,
    ' and one form to promote.
    function _ask_html(got, name, draft, question, problem)
        q = chr(34)
        p = got.p
        rec = got.rec
        tok = gdash_session.csrf_for(secret_of(p), got.viewer.sid)
        h = "<!doctype html><html><head><meta charset=" + q + "utf-8" + q + "><title>Ask " + gdash_render.html_escape(name) + "</title><style>" + _style() + "</style></head><body>"
        h = h + _who_bar(p, got.viewer)
        h = h + "<h1>Ask " + gdash_render.html_escape(string(default(rec["title"], name))) + "</h1>"
        h = h + "<p class=" + q + "gdash-stale" + q + ">A question here produces a <strong>draft</strong>: the query it generated, what its numbers mean, and what it draws. Nothing changes the dashboard until you promote it. <a href=" + q + "/d/" + gdash_render.html_escape(name) + q + ">Back to the dashboard</a></p>"

        h = h + "<form class=" + q + "gdash-ask" + q + " method=" + q + "post" + q + " action=" + q + "/d/" + name + "/ask" + q + ">"
        h = h + "<input type=" + q + "hidden" + q + " name=" + q + "csrf" + q + " value=" + q + tok + q + ">"
        h = h + "<input name=" + q + "question" + q + " size=" + q + "60" + q + " placeholder=" + q + "how many orders were over 1000 dollars?" + q + " value=" + q + gdash_render.html_escape(question) + q + ">"
        h = h + "<button type=" + q + "submit" + q + ">Ask</button>"
        h = h + "</form>"

        if problem != "" then
            h = h + "<div class=" + q + "gdash-error" + q + ">" + gdash_render.html_escape(problem) + "</div>"
        end if

        if is_unknown(draft) then
            return h + "</body></html>"
        end if

        if not draft.ok then
            h = h + "<div class=" + q + "gdash-error" + q + ">" + gdash_render.html_escape(draft.message) + "</div>"
            i = 0
            while i < count(draft.candidates)
                h = h + "<div class=" + q + "gdash-stale" + q + ">it could mean: " + gdash_render.html_escape(string(draft.candidates[i])) + "</div>"
                i += 1
            end while
            if draft.sql != "" then
                h = h + "<pre class=" + q + "gdash-sql" + q + ">" + gdash_render.html_escape(draft.sql) + "</pre>"
            end if
            i = 0
            while i < count(draft.problems)
                h = h + "<div class=" + q + "gdash-stale" + q + ">" + gdash_render.html_escape(string(draft.problems[i])) + "</div>"
                i += 1
            end while
            return h + "</body></html>"
        end if

        h = h + "<pre class=" + q + "gdash-sql" + q + ">" + gdash_render.html_escape(draft.sql) + "</pre>"

        ' THE UNIT NOTES COME BEFORE THE ANSWER, deliberately. A number read
        ' first is a number believed first.
        if count(draft.notes) > 0 then
            h = h + "<div class=" + q + "gdash-notes" + q + "><strong>Check the numbers in that query:</strong><ul>"
            i = 0
            while i < count(draft.notes)
                n = draft.notes[i]
                h = h + "<li>" + gdash_render.html_escape(n.column + " " + n.literal) + " means <strong>" + gdash_render.html_escape(n.means) + "</strong></li>"
                i += 1
            end while
            h = h + "</ul></div>"
        end if

        lines = []
        i = 0
        while i < count(draft.as_of)
            lines = concat(lines, [gdash_render.html_escape(draft.as_of[i].dataset + ": data as of " + draft.as_of[i].text)])
            i += 1
        end while
        h = h + "<div class=" + q + "gdash-stale" + q + ">" + join(lines, " &middot; ") + "</div>"

        vis = gdash_ask.draft_visual(draft, rec, draft.scaled)
        themed = gdash_theme.load_theme(p)
        h = h + "<div class=" + q + "gdash-preview-visual" + q + ">" + _draft_fragment(p, name, "draft", rec, vis, themed.theme) + "</div>"

        h = h + "<form class=" + q + "gdash-ask" + q + " method=" + q + "post" + q + " action=" + q + "/d/" + name + "/ask/promote" + q + ">"
        h = h + "<input type=" + q + "hidden" + q + " name=" + q + "csrf" + q + " value=" + q + tok + q + ">"
        h = h + "<span>Promote this as</span> "
        h = h + "<input name=" + q + "visual" + q + " placeholder=" + q + "a name for the visual" + q + ">"
        h = h + "<button type=" + q + "submit" + q + ">Add it to the dashboard</button>"
        h = h + "</form>"
        return h + "</body></html>"
    end function

    ' The suggested visual, drawn the way a promoted one is drawn. Same query
    ' path, same attach set, same renderer -- so a preview that draws is a
    ' promise that the promoted visual draws.
    function _draft_fragment(p, name, mode, rec, vis, theme)
        db = gdash_paths.dataset_db(p, name, mode, vis.dataset)
        if not gdash_paths.path_exists(db) then
            return "<div class=" + chr(34) + "gdash-empty" + chr(34) + ">No data yet -- this dataset has never refreshed.</div>"
        end if
        attach = _attach_for(p, name, mode, rec, vis.dataset)
        res = gdash_store.select_rows(db, vis.sql, {}, gdash_render.exact_columns(vis), attach)
        if not res.ok then
            return "<div class=" + chr(34) + "gdash-error" + chr(34) + ">the promoted query would fail: " + gdash_render.html_escape(res.message) + "</div>"
        end if
        return gdash_render.render_visual("draft", vis, res.rows, db, attach, theme)
    end function

    ' Editors get a way in. A feature nobody can find is a feature nobody has,
    ' and the CLI is not where a dashboard'"'"'s editors necessarily live.
    function _ask_link(got, name)
        if not allowed(got.rec, got.viewer, "edit") then
            return ""
        end if
        q = chr(34)
        return "<p class=" + q + "gdash-stale" + q + "><a href=" + q + "/d/" + gdash_render.html_escape(name) + "/ask" + q + ">Ask this data a question</a></p>"
    end function

    function dashboard_page(req, name)
        got = _load_dashboard(req, name, "view")
        if not got.ok then
            return got.response
        end if
        rec = got.rec
        p = got.p
        mode = got.mode
        asked = _request_opens(p, name, mode, rec)
        ' Read ONCE per page, not once per visual: a dashboard with six charts
        ' would otherwise open the same small file six times. A malformed
        ' theme is logged and ignored -- colours are decoration, and refusing
        ' to serve a dashboard over them would be the worse failure.
        themed = gdash_theme.load_theme(p)
        theme = themed.theme
        if not themed.ok then
            logged = gdash_audit.event(p, "theme.invalid", { reason: join(themed.errors, "; ") })
        end if
        values = gdash_record.resolve_params(rec, req.query, _effective_identity(got, name))

        tabs = rec["tabs"]
        ' Every tab renders server-side in one response and switches on the
        ' client. Workers share no in-memory state (design §5), so a tab
        ' switch that needed a round trip would have nowhere to remember
        ' which tab a viewer is on.
        navs = []
        panes = []
        ti = 0
        while ti < count(tabs)
            tname = string(default(tabs[ti]["name"], "Tab " + string(ti + 1)))
            sel = ""
            hidden = " hidden"
            if ti = 0 then
                sel = " gdash-tab-active"
                hidden = ""
            end if
            navs = concat(navs, ["<button class=" + chr(34) + "gdash-tab" + sel + chr(34) + " data-tab=" + chr(34) + string(ti) + chr(34) + " onclick=" + chr(34) + "gdashTab(this)" + chr(34) + ">" + gdash_render.html_escape(tname) + "</button>"])
            panes = concat(panes, ["<div class=" + chr(34) + "gdash-pane" + chr(34) + " data-pane=" + chr(34) + string(ti) + chr(34) + hidden + ">" + _layout(p, name, mode, rec, tabs[ti]["layout"], values, theme) + "</div>"])
            ti += 1
        end while
        tabbar = ""
        if count(tabs) > 1 then
            tabbar = "<div class=" + chr(34) + "gdash-tabs" + chr(34) + ">" + join(navs, "") + "</div>"
        end if
        body = tabbar + join(panes, "")
        q = chr(34)
        html = "<!doctype html><html><head><meta charset=" + q + "utf-8" + q + "><title>" + string(default(rec["title"], name)) + "</title><style>" + _style() + "</style></head><body>"
        html = html + _who_bar(p, got.viewer)
        html = html + _preview_bar(got, name)
        html = html + _ask_link(got, name)
        html = html + "<h1>" + string(default(rec["title"], name)) + "</h1>"
        html = html + "<div class=" + q + "gdash-stale" + q + ">" + _status_block(p, name, mode, rec) + "</div>"
        ' Hidden until a publish is observed. The viewer decides when to move.
        html = html + "<div id=" + q + "gdash-notice" + q + " class=" + q + "gdash-notice" + q + " hidden>A new version of this dashboard has been published. <a href=" + q + "" + q + " onclick=" + q + "location.reload();return false" + q + ">Reload to see it.</a></div>"
        html = html + body
        ' Read after every fragment has rendered, so the baseline can only be
        ' the same version the page shows or newer -- never older, which would
        ' make the first poll reload a page that was already current.
        html = html + "<script>" + _shim(gdash_store.read_version(gdash_paths.version_file(p, name, mode)), gdash_paths.read_pointer(p, name)) + "</script>"
        html = html + "</body></html>"

        ' Pin at session open (design §7). Re-set only when the browser is not
        ' already holding the snapshot we served -- a first visit, or a pin
        ' whose snapshot is gone and fell back to `current`.
        if got.snapshot != "" and got.pin_was != got.snapshot then
            return { body: html, headers: { "content-type": "text/html; charset=utf-8" }, cookies: [_pin_cookie(name, got.snapshot)] }
        end if
        return _html(html)
    end function

    ' Exactly the visuals whose query text binds the changed param re-run
    ' (design §2). A visual that does not bind it is not in the response at
    ' all, so the browser leaves it alone.
    function params_changed(req, name)
        got = _load_dashboard(req, name, "view")
        if not got.ok then
            return got.response
        end if
        rec = got.rec
        p = got.p
        mode = got.mode

        ' A param change is a read: it re-renders fragments and stores
        ' nothing. It carries no CSRF token because it changes no state.
        supplied = req["json"]
        if is_unknown(supplied) then
            supplied = {}
        end if
        values = gdash_record.resolve_params(rec, supplied, _effective_identity(got, name))
        themed = gdash_theme.load_theme(p)
        theme = themed.theme

        changed = keys(supplied)
        moving = []
        i = 0
        while i < count(changed)
            hit = gdash_record.visuals_binding(rec, changed[i])
            j = 0
            while j < count(hit)
                if not contains(moving, hit[j]) then
                    moving = concat(moving, [hit[j]])
                end if
                j += 1
            end while
            i += 1
        end while

        frags = {}
        i = 0
        while i < count(moving)
            frags[moving[i]] = _visual_fragment(p, name, mode, rec, moving[i], values, theme)
            i += 1
        end while
        return _json({ fragments: frags, rerendered: moving })
    end function

    function refresh(req, name)
        got = _load_dashboard(req, name, "edit")
        if not got.ok then
            return got.response
        end if
        if not csrf_present(req, got.p, got.viewer) then
            return _refuse(400, "missing or invalid CSRF token")
        end if
        rec = got.rec
        p = got.p
        mode = got.mode

        profiles = gdash_refresh.load_profiles(p)
        ds_names = keys(rec["datasets"])
        done = []
        i = 0
        while i < count(ds_names)
            dn = ds_names[i]
            pname = rec["datasets"][dn]["profile"]
            prof = profiles[pname]
            if is_unknown(prof) then
                return _refuse(500, "no connection profile named '" + string(pname) + "'")
            end if
            ' A person pressed the button, so the trigger is manual whatever
            ' the policy says -- including on a draft, which is the only way a
            ' draft ever refreshes at all (design §3).
            r = gdash_refresh.run(p, name, mode, rec, dn, prof, "manual")
            if not r.ok then
                ' The old dataset is still there and still correct.
                return _refuse(502, r.message)
            end if
            done = concat(done, [dn])
            i += 1
        end while
        return _json({ refreshed: done })
    end function

    ' The two texts and the diff between them. Design §7's "what changed
    ' between the numbers the CFO saw Tuesday and today" -- the endpoint hands
    ' back both records as well as the diff, because a reader who disagrees
    ' with the diff should be able to check it against the sources.
    '
    ' Access is the dashboard's: a snapshot is a version of a dashboard, so
    ' whoever may not see the dashboard may not see its history either.
    function diff(req, name)
        got = _load_dashboard(req, name, "view")
        if not got.ok then
            return got.response
        end if
        p = got.p
        have = gdash_publish.snapshots(p, name)
        if count(have) = 0 then
            return _refuse(404, "dashboard '" + name + "' has never been published")
        end if

        q = req["query"]
        if is_unknown(q) then
            q = {}
        end if
        to_leaf = string(default(q["to"], gdash_paths.read_pointer(p, name)))
        if to_leaf = "" then
            to_leaf = have[count(have) - 1]
        end if
        from_leaf = string(default(q["from"], ""))
        if from_leaf = "" then
            k = 0
            while k < count(have)
                if have[k] = to_leaf and k > 0 then
                    from_leaf = have[k - 1]
                end if
                k += 1
            end while
        end if
        if from_leaf = "" then
            return _refuse(400, "dashboard '" + name + "' has only one snapshot; there is nothing to compare it with")
        end if

        a = gdash_publish.snapshot_text(p, name, from_leaf)
        if is_unknown(a) then
            return _refuse(404, "no such snapshot: " + from_leaf)
        end if
        b = gdash_publish.snapshot_text(p, name, to_leaf)
        if is_unknown(b) then
            return _refuse(404, "no such snapshot: " + to_leaf)
        end if
        return _json({ from: from_leaf, to: to_leaf, changed: gdash_diff.changed(string(a), string(b)), diff: gdash_diff.unified(string(a), string(b), from_leaf, to_leaf, 3), from_text: string(a), to_text: string(b) })
    end function

    ' --- login, logout, and the CSRF gate ---------------------------------

    ' Every state-changing route passes through here. A GET never does: if
    ' that stops being true the route is wrong, not the check.
    function csrf_present(req, p, v)
        supplied = ""
        f = req["form"]
        if not is_unknown(f) then
            supplied = string(default(f["csrf"], ""))
        end if
        if supplied = "" then
            h = req["headers"]
            if not is_unknown(h) then
                supplied = string(default(h["x-gdash-csrf"], ""))
            end if
        end if
        return gdash_session.csrf_ok(secret_of(p), v.sid, supplied)
    end function

    function _login_html(p, sid, message, target)
        q = chr(34)
        tok = gdash_session.csrf_for(secret_of(p), sid)
        note = ""
        if message != "" then
            note = "<p class=" + q + "gdash-error" + q + ">" + gdash_render.html_escape(message) + "</p>"
        end if
        h = "<!doctype html><html><head><meta charset=" + q + "utf-8" + q + "><title>gdash — sign in</title><style>" + _style() + "</style></head><body>"
        h = h + "<h1>Sign in</h1>" + note
        h = h + "<form method=" + q + "post" + q + " action=" + q + "/login" + q + " class=" + q + "gdash-login" + q + ">"
        h = h + "<input type=" + q + "hidden" + q + " name=" + q + "csrf" + q + " value=" + q + tok + q + ">"
        h = h + "<input type=" + q + "hidden" + q + " name=" + q + "next" + q + " value=" + q + gdash_render.html_escape(target) + q + ">"
        h = h + "<label>Username<br><input name=" + q + "user" + q + " autocomplete=" + q + "username" + q + " autofocus></label>"
        h = h + "<label>Password<br><input name=" + q + "pass" + q + " type=" + q + "password" + q + " autocomplete=" + q + "current-password" + q + "></label>"
        h = h + "<button type=" + q + "submit" + q + ">Sign in</button>"
        h = h + "</form></body></html>"
        return h
    end function

    ' A session exists before login so that the CSRF token on the form has
    ' something to be bound to. It carries no user and no privilege; the id it
    ' holds is thrown away the moment one is granted.
    function login_form(req)
        p = paths_for(req)
        v = viewer_of(req, p)
        target = ""
        q = req["query"]
        if not is_unknown(q) then
            target = string(default(q["next"], ""))
        end if
        if v.sid != "" then
            return { body: _login_html(p, v.sid, "", target), headers: { "content-type": "text/html; charset=utf-8" } }
        end if
        fresh = gdash_session.create(_store(p), "", epoch())
        if not fresh.ok then
            return _refuse(500, "could not start a session")
        end if
        return { body: _login_html(p, fresh.session.id, "", target), headers: { "content-type": "text/html; charset=utf-8" }, cookies: [gdash_session.cookie("gdash_session", fresh.session.id, _secure(req), gdash_session.limits().absolute)] }
    end function

    ' Only a local path, and only one that cannot leave this site. A `next` of
    ' "//evil.example" is a protocol-relative URL a browser follows off-site.
    function safe_next(target)
        if target = "" then
            return "/"
        end if
        if not starts_with(target, "/") then
            return "/"
        end if
        if starts_with(target, "//") then
            return "/"
        end if
        if contains(target, chr(10)) or contains(target, chr(13)) then
            return "/"
        end if
        return target
    end function

    function login(req)
        p = paths_for(req)
        v = viewer_of(req, p)
        f = req["form"]
        if is_unknown(f) then
            f = {}
        end if
        target = safe_next(string(default(f["next"], "")))

        if not csrf_present(req, p, v) then
            return { status: 400, body: _login_html(p, v.sid, "That form expired. Try again.", target), headers: { "content-type": "text/html; charset=utf-8" } }
        end if

        cfg = gdash_authcfg.load_config(p)
        if not cfg.ok then
            ' A configuration gdash cannot read is not a configuration with
            ' nothing in it. Local accounts still work -- that is the point of
            ' local being first -- but the operator is told, in the log, what
            ' is wrong with the file.
            logged = gdash_audit.event(p, "auth.config.invalid", { reason: join(cfg.errors, "; ") })
        end if
        chain = gdash_authcfg.chain_from(p, cfg.config)

        who = string(default(f["user"], ""))

        ' SLOW A GUESSER DOWN, per username, before spending a hash on them.
        ' The wait applies whether or not the account exists, so it says
        ' nothing about which -- the same rule as the one refusal message.
        lim = gdash_throttle.throttle_limits()
        key = gdash_throttle.key_for(who)
        waiting = gdash_throttle.delay_remaining(gdash_throttle.read_attempts(p, key), epoch(), lim)
        if waiting > 0 then
            logged = gdash_audit.event(p, "login.throttled", { user: who, seconds: waiting })
            return { status: 429, body: _login_html(p, v.sid, "Too many attempts. Try again in " + string(waiting) + " seconds.", target), headers: { "content-type": "text/html; charset=utf-8", "retry-after": string(waiting) } }
        end if

        got = gdash_auth.sign_in(chain, who, string(default(f["pass"], "")))
        if not got.ok then
            ' The username is audited; the password is not, was not read into
            ' any other variable, and does not appear in the response. A
            ' directory that is down is audited as an outage and shown as one,
            ' never as a wrong password -- telling someone their password is
            ' wrong when the directory is down sends them to reset a password
            ' that was fine.
            if got.unavailable then
                logged = gdash_audit.event(p, "login.unavailable", { user: who, provider: got.provider })
                return { status: 503, body: _login_html(p, v.sid, got.message, target), headers: { "content-type": "text/html; charset=utf-8" } }
            end if
            logged = gdash_audit.event(p, "login.failed", { user: who })
            stored = gdash_throttle.write_attempts(p, key, gdash_throttle.after_failure(gdash_throttle.read_attempts(p, key), epoch(), lim))
            return { status: 401, body: _login_html(p, v.sid, got.message, target), headers: { "content-type": "text/html; charset=utf-8" } }
        end if

        ' The session-fixation defence: a privilege change gets a new id, so
        ' an id an attacker planted before login is not the id that carries
        ' the privilege after it.
        fresh = gdash_session.regenerate(_store(p), v.sid, epoch())
        if not fresh.ok then
            return _refuse(500, "could not start a session")
        end if
        bound = gdash_session.assign(_store(p), fresh.session.id, got.identity.name, _remember(got.provider, got.identity, epoch()), epoch())
        if not bound.ok then
            return _refuse(500, "could not start a session")
        end if
        ' A success forgets the failures. Somebody who mistypes twice and then
        ' gets it right is not a threat, and leaving the counter standing would
        ' make their next mistake more expensive than their first.
        cleared = gdash_throttle.clear_attempts(p, key)
        logged = gdash_audit.event(p, "login", { user: got.identity.name, provider: got.provider })
        return { status: 303, headers: { "content-type": "text/html; charset=utf-8", "location": target }, body: "", cookies: [gdash_session.cookie("gdash_session", fresh.session.id, _secure(req), gdash_session.limits().absolute)] }
    end function

    function logout(req)
        p = paths_for(req)
        v = viewer_of(req, p)
        if not csrf_present(req, p, v) then
            return _refuse(400, "that form expired")
        end if
        if v.authed then
            logged = gdash_audit.event(p, "logout", { user: v.name })
        end if
        ' Regenerate rather than merely destroy: logging out is a privilege
        ' change too, and a browser that keeps its old id keeps a name for
        ' something someone else might later be given.
        dropped = gdash_session.destroy(_store(p), v.sid)
        return { status: 303, headers: { "location": "/login" }, body: "", cookies: [gdash_session.clearing_cookie("gdash_session", _secure(req))] }
    end function

    function whoami(req)
        p = paths_for(req)
        v = viewer_of(req, p)
        return _json({ authenticated: v.authed, user: v.name, groups: v.groups, admin: v.admin, csrf: gdash_session.csrf_for(secret_of(p), v.sid) })
    end function

    ' The dashboards THIS viewer may open, and nothing about any other.
    '
    ' gdash had no way to answer "what is here?" from a browser: the root page
    ' said "open /d/<dashboard>" without saying which, so every viewer had to
    ' be told a URL by somebody who already knew it.
    '
    ' THE WHOLE DIFFICULTY IS THAT A NAME IS INFORMATION. Design §8 has an
    ' anonymous viewer refused a dashboard with 404 rather than 403 precisely
    ' because "layoffs-q3 exists" is itself a disclosure. An index is a list of
    ' names, so it must apply exactly the same predicate the page applies, and
    ' a dashboard the viewer could not open must be absent -- not greyed out,
    ' not counted, absent.
    '
    ' It therefore reuses `allowed` rather than re-deriving the rule. A second
    ' implementation of an access decision is a second thing to keep right.
    function _visible_dashboards(p, v)
        out = []
        names = gdash_refresh.dashboards(p)
        i = 0
        while i < count(names)
            pub = gdash_paths.publication(p, names[i])
            loaded = gdash_record.load_file(pub.record_file)
            ' A record that does not load is not listed. The operator sees it
            ' in `gdash list`; a viewer has nothing to do about it, and a
            ' broken record is not a reason to disclose that it exists.
            if loaded.ok then
                if allowed(loaded.record, v, "view") then
                    out = concat(out, [{ name: names[i], title: string(default(loaded.record["title"], names[i])) }])
                end if
            end if
            i += 1
        end while
        return out
    end function

    ' Deliberately the same words whether there are no dashboards at all or
    ' none this viewer may see. "3 dashboards exist, none for you" is exactly
    ' the disclosure the index is careful not to make, and a count is the
    ' easiest way to make it by accident.
    function _index_empty_text(authed)
        if authed then
            return "No dashboards are shared with you."
        end if
        return "No dashboards are available. <a href=" + chr(34) + "/login" + chr(34) + ">Sign in</a> if you have an account."
    end function

    function index_page(req)
        p = paths_for(req)
        v = viewer_of(req, p)
        visible = _visible_dashboards(p, v)
        q = chr(34)
        html = "<!doctype html><html><head><meta charset=" + q + "utf-8" + q + "><title>gdash</title><style>" + _style() + "</style></head><body>"
        html = html + _who_bar(p, v)
        html = html + "<h1>gdash</h1>"
        if count(visible) = 0 then
            ' Deliberately the same words whether there are no dashboards at
            ' all or none this viewer may see. The alternative -- "3 dashboards
            ' exist, none for you" -- discloses the thing the index is careful
            ' not to.
            html = html + "<p class=" + q + "gdash-empty" + q + ">" + _index_empty_text(v.authed) + "</p>"
        else
            html = html + "<ul class=" + q + "gdash-index" + q + ">"
            i = 0
            while i < count(visible) 
                html = html + "<li><a href=" + q + "/d/" + gdash_render.html_escape(visible[i].name) + q + ">" + gdash_render.html_escape(visible[i].title) + "</a></li>"
                i += 1
            end while
            html = html + "</ul>"
        end if
        html = html + "</body></html>"
        return _html(html)
    end function

    ' The two global facts a viewer's page needs to know it has gone stale:
    ' the dataset version and the publish pointer. Both are read from the
    ' filesystem, which is what design §5 actually requires -- any worker can
    ' answer this, because the truth is on disk and not in anyone's memory.
    '
    ' This is the whole of what the SSE stream used to carry, and the loop
    ' that read these two files now runs in the browser instead of in a
    ' handler that never returned (GDASH-11). The rename-swap still guarantees
    ' that a reader who sees a new version sees complete data.
    '
    ' Access is checked exactly as the page checks it. A version number is
    ' small, but "this dashboard exists and its data moved at 14:02" is not
    ' nothing, and an endpoint that answered more freely than the page would
    ' be a way to watch a dashboard you cannot open.
    function version_of(req, name)
        got = _load_dashboard(req, name, "view")
        if not got.ok then
            return got.response
        end if
        p = got.p
        return _json({ v: gdash_store.read_version(gdash_paths.version_file(p, name, got.mode)), pub: gdash_paths.read_pointer(p, name) })
    end function

end library
