' gdash — path resolver.
'
' Every path gdash uses is minted here. No path literal exists outside this
' module (CLAUDE.md). `--root <dir>` collapses all five FHS roles under one
' directory, which is what lets the suite run hermetically in a temp dir with
' no installed system state and no root privileges; a Windows port would be
' one function (design §6).

library gdash_paths

    function _join(a, b)
        if a = "" then
            return b
        end if
        if mid(a, len(a) - 1, 1) = "/" then
            return a + b
        end if
        return a + "/" + b
    end function

    function _last_slash(s)
        i = len(s) - 1
        while i > 0
            if mid(s, i, 1) = "/" then
                return i
            end if
            i -= 1
        end while
        return 0
    end function

    ' `exists` accepts only a FILE reference, but a file reference over a
    ' directory path answers correctly, so this is the one existence test for
    ' both kinds. `list()` cannot serve: it returns an empty array for a
    ' missing directory rather than raising, so it cannot tell absent from
    ' empty.
    function path_exists(path)
        on error goto next
        f {file} = path
        if error then
            return false
        end if
        e = exists(f)
        if error then
            return false
        end if
        return e
    end function

    ' Idempotent, and creates missing parents. Bare `make_dir` does neither.
    function ensure_dir(path)
        if path = "" then
            return false
        end if
        if path_exists(path) then
            return true
        end if
        cut = _last_slash(path)
        if cut > 0 then
            parent = mid(path, 0, cut)
            made = ensure_dir(parent)
        end if
        on error goto next
        make_dir(path)
        if error then
            ' A concurrent creator is success, not failure.
            return path_exists(path)
        end if
        return true
    end function

    ' root = "" means FHS (installed); otherwise every role lives under root.
    function roles(root)
        if root = "" then
            return { mode: "fhs", root: "", config_dir: "/etc/gdash", state_dir: "/var/lib/gdash", cache_dir: "/var/cache/gdash", log_dir: "/var/log/gdash", run_dir: "/run/gdash" }
        end if
        return { mode: "root", root: root, config_dir: _join(root, "etc"), state_dir: _join(root, "lib"), cache_dir: _join(root, "cache"), log_dir: _join(root, "log"), run_dir: _join(root, "run") }
    end function

    function from_args(args)
        root = ""
        i = 0
        while i < count(args)
            if args[i] = "--root" then
                if i + 1 < count(args) then
                    root = args[i + 1]
                end if
            end if
            i += 1
        end while
        return roles(root)
    end function

    ' Precious state (design §6): /var/lib is the entire backup set.
    function dashboards_dir(p)
        return _join(p.state_dir, "dashboards")
    end function

    function dashboard_dir(p, name)
        return _join(dashboards_dir(p), name)
    end function

    ' The draft is the one mutable record; editing touches it and nothing else
    ' (design §7). Draft datasets refresh manually only -- see `publication`
    ' for how the served record, and therefore the policy, is decided.
    function record_file(p, name)
        return _join(dashboard_dir(p, name), "draft.json")
    end function

    ' Design §7: publish copies the draft to snapshots/NNNN.json and
    ' atomically repoints `current`. GDASH-2 implements the READ side only --
    ' resolving the pointer -- because without it the scheduler has nothing to
    ' schedule. Every write (publish, rollback, diff, pinning) is GDASH-3's,
    ' and if it rules the pointer differently, this is the one function that
    ' changes.
    function snapshot_dir(p, name)
        return _join(dashboard_dir(p, name), "snapshots")
    end function

    function current_pointer(p, name)
        return _join(dashboard_dir(p, name), "current")
    end function

    function snapshot_file(p, name, leaf)
        return _join(snapshot_dir(p, name), leaf)
    end function

    ' A snapshot leaf resolved to a real file, or "" when it is not one.
    '
    ' The leaf names a snapshot inside the dashboard's own snapshot directory.
    ' It never names a path: a `current` -- or a viewer's pin cookie -- holding
    ' "../../etc/gdash/connections.json" would otherwise read credentials as a
    ' record. Both callers go through here so neither can forget.
    function resolve_snapshot(p, name, leaf)
        if leaf = "" then
            return ""
        end if
        if contains(leaf, "/") then
            return ""
        end if
        snap = snapshot_file(p, name, leaf)
        if not path_exists(snap) then
            return ""
        end if
        return snap
    end function

    function read_pointer(p, name)
        ptr = current_pointer(p, name)
        if not path_exists(ptr) then
            return ""
        end if
        on error goto next
        cf {file} = ptr
        leaf = trim(read(cf))
        if error then
            return ""
        end if
        return leaf
    end function

    ' Which record is served, and therefore which data directory applies.
    ' Returns { mode, record_file, published, snapshot }. A dashboard with no
    ' `current` is a draft, which is the honest answer for one that has never
    ' been published.
    function publication(p, name)
        leaf = read_pointer(p, name)
        snap = resolve_snapshot(p, name, leaf)
        if snap = "" then
            return { mode: "draft", record_file: record_file(p, name), published: false, snapshot: "" }
        end if
        return { mode: "published", record_file: snap, published: true, snapshot: leaf }
    end function

    ' A viewer resolves `current` at session open and PINS that snapshot for
    ' the session (design §7): publish never coordinates with live sessions,
    ' and no one sees a half-updated dashboard. A pin naming a snapshot that
    ' is no longer there falls back to `current` rather than failing -- the
    ' viewer asked for a coherent read, not for that exact file.
    function pinned(p, name, leaf)
        snap = resolve_snapshot(p, name, leaf)
        if snap = "" then
            return publication(p, name)
        end if
        return { mode: "published", record_file: snap, published: true, snapshot: leaf }
    end function

    ' Disposable cache: may be deleted whenever the service is stopped. Draft
    ' and published data never share a directory, because a draft edit must
    ' not be able to leak into production (design §7) and the cheapest way to
    ' guarantee that is for the two never to name the same file.
    function data_dir(p, name, mode)
        return _join(_join(p.cache_dir, name), mode)
    end function

    function dataset_db(p, name, mode, ds)
        return _join(data_dir(p, name, mode), ds + ".db")
    end function

    function dataset_staging(p, name, mode, ds)
        return _join(data_dir(p, name, mode), ds + "__staging.db")
    end function

    ' Last attempt, last success, last error, row count, content hash and any
    ' pending refresh request. Beside the data it describes, so deleting the
    ' cache directory forgets the state with it -- which is correct: state
    ' about data that is gone is not state worth keeping.
    function dataset_state(p, name, mode, ds)
        return _join(data_dir(p, name, mode), ds + ".state.json")
    end function

    function dataset_lock(p, name, mode, ds)
        return _join(data_dir(p, name, mode), ds + ".lock")
    end function

    function version_file(p, name, mode)
        return _join(data_dir(p, name, mode), "version")
    end function

    function connections_file(p)
        return _join(p.config_dir, "connections.json")
    end function

    function audit_log(p)
        return _join(p.log_dir, "audit.log")
    end function

    ' No chmod builtin exists, so the mode is set by calling out. Lives here
    ' because gdash_refresh and gdash_users both need it and two copies of a
    ' permission-setting call is two places for one of them to be forgotten.
    function restrict(path)
        on error goto next
        r = process.run({ command: "chmod", args: ["600", path] })
        if error then
            return false
        end if
        return r.exit_code = 0
    end function

    ' Runtime state: /run is cleared on reboot, which is the correct lifetime
    ' for a session (design §6 puts pid and control socket here for the same
    ' reason).
    function session_dir(p)
        return _join(p.run_dir, "sessions")
    end function

    function session_file(p, id)
        return _join(session_dir(p), id + ".json")
    end function

    ' 0600, and never in a record, a commit or a test fixture (CLAUDE.md).
    function users_file(p)
        return _join(p.config_dir, "users.json")
    end function

    ' The CSRF secret. Server-level and generated at first use: a fixed secret
    ' in the source would make every deployment's tokens forgeable by anyone
    ' who read the source.
    function secret_file(p)
        return _join(p.config_dir, "secret")
    end function

    ' Credentials reach a refresh child through a 0600 file, never argv
    ' (design §3).
    function job_file(p, token)
        return _join(p.run_dir, "job-" + token + ".json")
    end function

    function describe(p)
        return "mode=" + p.mode + " config=" + p.config_dir + " state=" + p.state_dir + " cache=" + p.cache_dir + " log=" + p.log_dir + " run=" + p.run_dir
    end function

end library
