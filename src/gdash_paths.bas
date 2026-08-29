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
    function dashboard_dir(p, name)
        return _join(_join(p.state_dir, "dashboards"), name)
    end function

    ' GDASH-0 is draft-only: no publish, no snapshots (GDASH-3 owns those), and
    ' draft datasets refresh manually only (design §3) -- which is exactly this
    ' phase's refresh policy, so operating entirely in draft needs no deviation
    ' from the §6 layout.
    function record_file(p, name)
        return _join(dashboard_dir(p, name), "draft.json")
    end function

    ' Disposable cache: may be deleted whenever the service is stopped.
    function data_dir(p, name)
        return _join(_join(p.cache_dir, name), "draft")
    end function

    function dataset_db(p, name, ds)
        return _join(data_dir(p, name), ds + ".db")
    end function

    function dataset_staging(p, name, ds)
        return _join(data_dir(p, name), ds + "__staging.db")
    end function

    function version_file(p, name)
        return _join(data_dir(p, name), "version")
    end function

    function connections_file(p)
        return _join(p.config_dir, "connections.json")
    end function

    function audit_log(p)
        return _join(p.log_dir, "audit.log")
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
