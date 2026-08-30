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
' the visuals that bind that param. SSE carries only global events, observed
' through the filesystem by polling the per-dashboard version file, so any
' worker can see them independently.
'
' Every handler carries its own `load` lines: a module is visible only inside
' the block that loads it (finding F3).

server gdash_web( port: 8780 )

    get "/"( req )
        return { body: "<!doctype html><meta charset=utf-8><title>gdash</title><p>gdash is running. Open /d/&lt;dashboard&gt;.", headers: { "content-type": "text/html; charset=utf-8" } }
    end get

    ' The shell: renders every visual and control once, server-side.
    get "/d/{name}"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.page(req, req.params.name)
    end get

    ' A slicer publishes a param; exactly the visuals binding it re-run.
    post "/d/{name}/params"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.params_changed(req, req.params.name)
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

    ' Global events only. The body polls the version file, so a refresh
    ' performed by any worker (or by the CLI) is seen by all of them.
    stream "/d/{name}/events"( req )
        load gdash_app from "gdash_app.bas"
        return gdash_app.events(req, req.params.name)
    end stream

end server

program main( args )
    load gdash_paths from "gdash_paths.bas"

    ' Handlers cannot see argv, so the root travels in the environment and
    ' both sides read the same place. --root stays the CLI's spelling.
    p = gdash_paths.roles(default(env("GDASH_ROOT"), ""))
    ' Resolved roles are logged at startup (design §6).
    print("gdash: " + gdash_paths.describe(p))

    made = gdash_paths.ensure_dir(p.state_dir)
    made = gdash_paths.ensure_dir(p.cache_dir)
    made = gdash_paths.ensure_dir(p.log_dir)
    made = gdash_paths.ensure_dir(p.run_dir)

    h = serve(gdash_web)
    print("gdash: listening on " + string(h.port))
end program
