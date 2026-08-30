' gdash — request handling.
'
' Kept out of the server block so the same logic is directly testable without
' a socket, and so each handler stays one line.

library gdash_app

    load gdash_paths from "gdash_paths.bas"
    load gdash_record from "gdash_record.bas"
    load gdash_store from "gdash_store.bas"
    load gdash_render from "gdash_render.bas"
    load gdash_refresh from "gdash_refresh.bas"
    load gdash_sched from "gdash_sched.bas"
    load gdash_publish from "gdash_publish.bas"
    load gdash_diff from "gdash_diff.bas"

    function _root_of(req)
        return default(env("GDASH_ROOT"), "")
    end function

    function paths_for(req)
        return gdash_paths.roles(_root_of(req))
    end function

    function _html_escape(text)
        t = replace(string(text), "&", "&amp;")
        t = replace(t, "<", "&lt;")
        t = replace(t, ">", "&gt;")
        t = replace(t, chr(34), "&quot;")
        return t
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
    function _load_dashboard(req, name)
        p = paths_for(req)
        if contains(name, "/") then
            return { ok: false, rec: {}, p: p, mode: "draft", snapshot: "", pin_was: "", response: _refuse(400, "bad dashboard name") }
        end if
        pin = _pin_of(req)
        pub = gdash_paths.pinned(p, name, pin)
        loaded = gdash_record.load_file(pub.record_file)
        if not loaded.ok then
            if contains(join(loaded.errors, "|"), "not found") then
                return { ok: false, rec: {}, p: p, mode: pub.mode, snapshot: pub.snapshot, pin_was: pin, response: _refuse(404, "no such dashboard: " + name) }
            end if
            return { ok: false, rec: {}, p: p, mode: pub.mode, snapshot: pub.snapshot, pin_was: pin, response: _refuse(500, "dashboard is invalid: " + join(loaded.errors, "; ")) }
        end if
        if not _access_ok(loaded.record) then
            return { ok: false, rec: {}, p: p, mode: pub.mode, snapshot: pub.snapshot, pin_was: pin, response: _refuse(403, "this dashboard does not grant open access") }
        end if
        return { ok: true, rec: loaded.record, p: p, mode: pub.mode, snapshot: pub.snapshot, pin_was: pin, response: {} }
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

    function _visual_fragment(p, name, mode, rec, vis_name, values)
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
        return gdash_render.render_visual(vis_name, v, res.rows, db, attach)
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

    function _layout(p, name, mode, rec, node, values)
        if not is_unknown(node["vert"]) then
            return _container(p, name, mode, rec, node, node["vert"], values, "gdash-vert")
        end if
        if not is_unknown(node["horiz"]) then
            return _container(p, name, mode, rec, node, node["horiz"], values, "gdash-horiz")
        end if
        if not is_unknown(node["visual"]) then
            vn = node["visual"]
            return "<div class=" + chr(34) + "gdash-cell" + chr(34) + " style=" + chr(34) + _child_style(node) + chr(34) + " data-visual=" + chr(34) + vn + chr(34) + ">" + _visual_fragment(p, name, mode, rec, vn, values) + "</div>"
        end if
        if not is_unknown(node["control"]) then
            return "<div class=" + chr(34) + "gdash-cell" + chr(34) + " style=" + chr(34) + _child_style(node) + chr(34) + ">" + _control_fragment(p, name, mode, rec, node["control"], values) + "</div>"
        end if
        return ""
    end function

    function _container(p, name, mode, rec, node, kids, values, cls)
        out = []
        i = 0
        while i < count(kids)
            out = concat(out, [_layout(p, name, mode, rec, kids[i], values)])
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

    function _when(at)
        if at = 0 then
            return "never"
        end if
        on error goto next
        t = from_epoch(at)
        if error then
            return string(at)
        end if
        return string(t)
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
            line = _html_escape(ds[i]) + ": data as of " + _html_escape(_when(st.last_success))
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
                line = line + " — last refresh failed: " + _html_escape(st.last_error)
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

    function _shim()
        q = chr(34)
        js = ""
        js = js + "function gdashParam(el){"
        js = js + "var b={};b[el.getAttribute('data-param')]=el.value;"
        js = js + "fetch(location.pathname+'/params',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})"
        js = js + ".then(function(r){return r.json()}).then(function(d){"
        js = js + "for(var k in d.fragments){var c=document.querySelector('[data-visual='+JSON.stringify(k)+']');if(c){c.innerHTML=d.fragments[k]}}"
        js = js + "});}"
        js = js + "function gdashTab(b){var i=b.getAttribute('data-tab');"
        js = js + "var ts=document.querySelectorAll('.gdash-tab');for(var j=0;j<ts.length;j++){ts[j].classList.toggle('gdash-tab-active',ts[j]===b)}"
        js = js + "var ps=document.querySelectorAll('.gdash-pane');for(var k=0;k<ps.length;k++){ps[k].hidden=(ps[k].getAttribute('data-pane')!==i)}}"
        js = js + "function gdashNotice(){var b=document.getElementById('gdash-notice');if(b){b.hidden=false}}"
        js = js + "var es=new EventSource(location.pathname+'/events');"
        js = js + "es.onmessage=function(e){"
        js = js + "if(e.data==='refresh'){location.reload()}"
        js = js + "else if(e.data==='publish'){gdashNotice()}"
        js = js + "};"
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
        s = s + ".gdash-stale{color:#666;font-size:12px;margin-bottom:12px;display:flex;flex-wrap:wrap;gap:16px}"
        s = s + ".gdash-stale-bad{color:#a00}"
        s = s + ".gdash-notice{border:1px solid #c90;background:#fffbe6;border-radius:6px;padding:10px 12px;margin-bottom:12px;font-size:13px}"
        s = s + ".gdash-tabs{display:flex;gap:4px;border-bottom:1px solid #ddd;margin-bottom:16px}"
        s = s + ".gdash-tab{border:0;background:none;padding:8px 14px;cursor:pointer;font-size:14px;color:#555;border-bottom:2px solid transparent}"
        s = s + ".gdash-tab-active{color:#111;border-bottom-color:#333;font-weight:600}"
        s = s + ".gdash-table table{border-collapse:collapse;width:100%;font-size:13px}"
        s = s + ".gdash-table th{text-align:left;border-bottom:1px solid #ccc;padding:6px 10px;color:#555;font-weight:600}"
        s = s + ".gdash-table td{border-bottom:1px solid #eee;padding:6px 10px;font-variant-numeric:tabular-nums}"
        s = s + ".gdash-table-title{font-size:12px;color:#666;margin-bottom:6px}"
        return s
    end function

    function page(req, name)
        got = _load_dashboard(req, name)
        if not got.ok then
            return got.response
        end if
        rec = got.rec
        p = got.p
        mode = got.mode
        asked = _request_opens(p, name, mode, rec)
        values = gdash_record.resolve_params(rec, req.query)

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
            navs = concat(navs, ["<button class=" + chr(34) + "gdash-tab" + sel + chr(34) + " data-tab=" + chr(34) + string(ti) + chr(34) + " onclick=" + chr(34) + "gdashTab(this)" + chr(34) + ">" + _html_escape(tname) + "</button>"])
            panes = concat(panes, ["<div class=" + chr(34) + "gdash-pane" + chr(34) + " data-pane=" + chr(34) + string(ti) + chr(34) + hidden + ">" + _layout(p, name, mode, rec, tabs[ti]["layout"], values) + "</div>"])
            ti += 1
        end while
        tabbar = ""
        if count(tabs) > 1 then
            tabbar = "<div class=" + chr(34) + "gdash-tabs" + chr(34) + ">" + join(navs, "") + "</div>"
        end if
        body = tabbar + join(panes, "")
        q = chr(34)
        html = "<!doctype html><html><head><meta charset=" + q + "utf-8" + q + "><title>" + string(default(rec["title"], name)) + "</title><style>" + _style() + "</style></head><body>"
        html = html + "<h1>" + string(default(rec["title"], name)) + "</h1>"
        html = html + "<div class=" + q + "gdash-stale" + q + ">" + _status_block(p, name, mode, rec) + "</div>"
        ' Hidden until a publish is observed. The viewer decides when to move.
        html = html + "<div id=" + q + "gdash-notice" + q + " class=" + q + "gdash-notice" + q + " hidden>A new version of this dashboard has been published. <a href=" + q + "" + q + " onclick=" + q + "location.reload();return false" + q + ">Reload to see it.</a></div>"
        html = html + body
        html = html + "<script>" + _shim() + "</script>"
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
        got = _load_dashboard(req, name)
        if not got.ok then
            return got.response
        end if
        rec = got.rec
        p = got.p
        mode = got.mode

        supplied = req["json"]
        if is_unknown(supplied) then
            supplied = {}
        end if
        values = gdash_record.resolve_params(rec, supplied)

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
            frags[moving[i]] = _visual_fragment(p, name, mode, rec, moving[i], values)
            i += 1
        end while
        return _json({ fragments: frags, rerendered: moving })
    end function

    function refresh(req, name)
        got = _load_dashboard(req, name)
        if not got.ok then
            return got.response
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
        got = _load_dashboard(req, name)
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

    ' Each stream body polls the per-dashboard version file and emits on
    ' change. The rename-swap guarantees a notified reader sees complete data.
    function events(req, name)
        got = _load_dashboard(req, name)
        if not got.ok then
            return 0
        end if
        p = got.p
        vfile = gdash_paths.version_file(p, name, got.mode)
        seen = gdash_store.read_version(vfile)
        ' `current` is polled alongside the data version, so publish needs no
        ' file of its own and a cache wipe cannot lose the signal.
        seen_pub = gdash_paths.read_pointer(p, name)

        alive = emit(req, "event: hello" + chr(10) + "data: " + string(seen) + chr(10) + chr(10))
        ticks = 0
        ' Every live stream pins a worker (design §5, the named ceiling), so a
        ' stream whose client has gone must be noticed promptly. emit is the
        ' only liveness signal there is -- its false return IS the protocol --
        ' so a comment line goes out on a heartbeat even when nothing has
        ' changed. Without it a departed reader would hold its worker until
        ' the tick ceiling.
        while alive and ticks < 7200
            sleep(0.5)
            now_v = gdash_store.read_version(vfile)
            now_pub = gdash_paths.read_pointer(p, name)
            if now_v != seen then
                seen = now_v
                alive = emit(req, "data: refresh" + chr(10) + chr(10))
            else if now_pub != seen_pub then
                ' A NOTICE, not a reload. Yanking the page out from under a
                ' pinned viewer is the thing pinning exists to prevent
                ' (design §7): new versions arrive on next open, or when the
                ' viewer decides.
                seen_pub = now_pub
                alive = emit(req, "data: publish" + chr(10) + chr(10))
            else if mod(ticks, 10) = 0 then
                alive = emit(req, ": ping" + chr(10) + chr(10))
            end if
            ticks += 1
        end while
        return 0
    end function

end library
