' gdash — the server.
'
' One gBASIC process using the PLAT-WEB server block. All queries execute
' server-side; the browser receives only visual-query results, which is what
' makes a user-filtered dashboard over a shared dataset genuinely secure --
' the trust boundary is the server and the staged dataset never leaves it
' (design §5).
'
' Workers share no in-memory state. Per-viewer interactivity therefore rides
' request/response: parameter values live in the page and travel with each
' request, and a param-change POST returns re-rendered fragments for exactly
' the visuals that bind that param. Global events are observed through the
' filesystem -- the per-dashboard version file and the publish pointer -- so
' any worker can answer for them independently.
'
' Design §5 names SSE as the carrier for those global events. It no longer is:
' the browser polls /d/{name}/version instead (GDASH-11). The principle §5 is
' actually protecting -- that the truth lives on disk and not in any worker's
' memory -- is unchanged, and the sentence is the maintainer's to correct.
'
' NOT because a stream would pin a worker. It would not: a stream handler that
' RETURNS parks the connection and frees its worker, and gdash's mistake was a
' handler that looped in sleep() instead (G11-13). The real reason is that a
' parked stream belongs to the worker that accepted it, so a notification that
' must reach every viewer would mean workers: 1 -- and workers are what stop a
' burst of page loads queueing. Polling is correct at any worker count.
'
' Every handler carries its own `load` lines: a module is visible only inside
' the block that loads it (finding F3).

server gdash_web( port: 8780 )

    ' The dashboards this viewer may open. It used to say "open
    ' /d/<dashboard>" without saying which, so a viewer could reach nothing
    ' without being told a URL by somebody who already knew it.
    get "/"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.index_page(req)
    end get

    ' Sign in and out. The login form is a GET so it can be linked to; the
    ' post carries a CSRF token bound to the pre-login session.
    get "/login"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.login_form(req)
    end get

    post "/login"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.login(req)
    end post

    post "/logout"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.logout(req)
    end post

    ' What the browser is currently authenticated as, and the CSRF token to
    ' use with it. The shim reads this rather than having it baked into every
    ' page.
    get "/whoami"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.whoami(req)
    end get

    ' The shell: renders every visual and control once, server-side.
    get "/d/{name}"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.dashboard_page(req, req.params.name)
    end get

    ' A slicer publishes a param; exactly the visuals binding it re-run.
    post "/d/{name}/params"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.params_changed(req, req.params.name)
    end post

    ' Preview-as: draft only, editors only, audited (design §8). It changes
    ' the injected user_* params and nothing about authorization.
    post "/d/{name}/preview"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.preview(req, req.params.name)
    end post

    ' A person asking, whatever the dataset's policy says (design §3).
    post "/d/{name}/refresh"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.refresh(req, req.params.name)
    end post

    ' The version history, as text and as a diff (design §7).
    get "/d/{name}/diff"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.diff(req, req.params.name)
    end get

    ' Global events, as two numbers the page polls (GDASH-11). This replaced
    ' an SSE stream whose body did exactly this read in a loop -- and a handler
    ' that loops is a worker that never comes back. With the default single
    ' worker, one open dashboard meant nothing else was served at all.
    '
    ' There is no `stream` route any more. Not because a stream must hold a
    ' worker -- a handler that returns parks the connection and does not --
    ' but because a parked stream is reachable only from the worker that
    ' accepted it, so a refresh notice would reach a fraction of viewers per
    ' write unless gdash ran a single worker (G11-13). Two numbers over an
    ' ordinary request reach everyone, at every worker count.
    get "/d/{name}/version"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.version_of(req, req.params.name)
    end get

end server

program main( args )
    load gdash_paths from "gdash_paths.bas"
    load web

    ' Handlers cannot see argv, so the root travels in the environment and
    ' both sides read the same place. --root stays the CLI's spelling.
    p = gdash_paths.roles(default(env("GDASH_ROOT"), ""))
    ' Resolved roles are logged at startup (design §6).
    print("gdash: " + gdash_paths.describe(p))

    made = gdash_paths.ensure_dir(p.state_dir)
    made = gdash_paths.ensure_dir(p.cache_dir)
    made = gdash_paths.ensure_dir(p.log_dir)
    made = gdash_paths.ensure_dir(p.run_dir)

    ' The worker count comes from the environment, not the source.
    '
    ' A `server` head takes literals, so until gbasic ca5df46 the count was
    ' fixed at 1 unless somebody edited this file -- and gdash's own
    ' multi-worker suite had to copy src/ to a scratch directory and rewrite
    ' the literal there, because committing a second copy of the routing table
    ' would have been two sources of truth for routing (finding G6-7).
    '
    ' `web.configure` returns another declaration with deployment settings
    ' merged in, so `web.routes`, `web.dispatch` and the outline still work on
    ' the result. It also VALIDATES: `app.options.workesr = 4` would have been
    ' accepted in silence, created a field nothing reads, and left the server
    ' on the declared value.
    workers = number(default(env("GDASH_WORKERS"), "1"))
    if workers < 1 then
        ' `workers: 0` raises since gbasic ca5df46 rather than quietly serving
        ' single-process. An operator who typed 0 meant one, not a dead server.
        workers = 1
    end if
    settings = { workers: workers }

    ' Port and address, because 8780 in the source is a decision an operator
    ' has to be able to make differently -- behind a proxy, on a second
    ' instance, or bound to one interface rather than all of them.
    if trim(string(default(env("GDASH_PORT"), ""))) != "" then
        settings["port"] = number(env("GDASH_PORT"))
    end if
    if trim(string(default(env("GDASH_ADDRESS"), ""))) != "" then
        settings["address"] = string(env("GDASH_ADDRESS"))
    end if

    ' TLS IS THE PLATFORM'S; gdash's whole job is to pass the pair through.
    ' Acquisition, renewal and rotation belong to the deployment, and a
    ' dashboard server that tried to own them would own them badly.
    '
    ' BOTH OR NEITHER. Half a pair is a configuration mistake, and starting in
    ' cleartext because the key was missing is the failure that matters: the
    ' operator believes the thing is encrypted. Design §6 recommends TLS rather
    ' than requiring it, so no TLS at all is allowed -- silently downgrading
    ' from configured TLS is not.
    cert = trim(string(default(env("GDASH_TLS_CERT"), "")))
    keyf = trim(string(default(env("GDASH_TLS_KEY"), "")))
    if cert != "" and keyf = "" then
        print to error "gdash: GDASH_TLS_CERT is set but GDASH_TLS_KEY is not; refusing to start in cleartext"
        exit(2)
    end if
    if keyf != "" and cert = "" then
        print to error "gdash: GDASH_TLS_KEY is set but GDASH_TLS_CERT is not; refusing to start in cleartext"
        exit(2)
    end if
    if cert != "" then
        ' REFUSING RATHER THAN SERVING IN THE CLEAR (finding G8-6).
        '
        ' `web.configure` accepts `cert` and `key` and stores them --
        ' cfg.options carries them -- but `serve` reads TLS from the
        ' pre-registered head instead, so a configured pair is silently
        ' ignored and the server listens in cleartext. Verified both ways at
        ' gbasic ca5df46: the same pair in the head gives HTTPS 200 and refuses
        ' plain HTTP; via configure it gives HTTPS nothing and plain HTTP 200.
        '
        ' gdash cannot detect this from what serve returns -- the server record
        ' has no TLS field -- so it cannot verify and must not pretend. An
        ' operator who configured TLS and got cleartext is worse off than one
        ' who was told to use a proxy: the first believes they are encrypted.
        print to error "gdash: TLS is configured, and this build cannot honour it."
        print to error "       web.configure accepts cert/key but serve ignores them (gbasic ca5df46),"
        print to error "       so starting would listen in CLEARTEXT while looking encrypted."
        print to error "       Terminate TLS at a reverse proxy until the platform carries it through."
        exit(2)
    end if

    h = web.serve(web.configure(gdash_web, settings))
    print("gdash: listening on " + string(h.port))
end program
