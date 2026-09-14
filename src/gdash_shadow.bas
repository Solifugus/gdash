' gdash — the shadowing refusal.
'
' gdash loads seven libraries by bare name, and a bare name does not resolve
' to the installed stdlib first. The platform searches the directory of the
' SOURCE FILE ISSUING THE LOAD -- recursively, subdirectories included --
' before it looks at GBASIC_PATH or the install tree. The first match wins and
' the real library is the one reported "ignored", on stderr, as a warning:
'
'   warning: additional library 'chart' match ignored:
'            /usr/local/share/gbasic/stdlib/chart.bas
'
' A service's stderr goes to a log nobody is reading at the moment it matters,
' so that notice is not a control. Measured at gbasic 159bc30: a chart.bas
' three directories below the loading file won over the stdlib, with that one
' line of warning and no other sign.
'
' Every bare-name load in gdash lives in a module under src/ -- installed, the
' libdir -- so one directory tree is the whole exposure, and it is a tree
' gdash can look at before it does anything else. `crypto` hashes every
' password and mints every session secret; `web` is the server itself. A
' replacement for either is not a bug to be found later.
'
' SCOPE, STATED. Only an exact `<name>.bas` is checked, because only an exact
' filename can win: the platform falls back to scanning arbitrary .bas files
' for a matching `library` block ONLY when nothing matched by name anywhere,
' and the stdlib always matches by name for a gdash that can run at all. If
' one of the seven ever went missing from the stdlib, gdash would fail to load
' it rather than silently accept a stray -- a different failure, and a loud
' one.

library gdash_shadow

    load gdash_paths from "gdash_paths.bas"

    ' The bare-name loads gdash performs. tests/test_shadow.bas reads every
    ' module under src/ and fails if this list and the source disagree, so a
    ' library added to gdash without being added here is a test failure rather
    ' than a silent gap in the guard.
    function guarded_names()
        return ["chart", "crypto", "ldap", "odbc", "pg", "sqlite", "web"]
    end function

    ' A depth cap, because this runs before gdash does anything and must not
    ' be the thing that hangs. The platform's own search has no cap; it does
    ' not need one for the reason this walk does not either -- a symlink loop
    ' runs out of path length -- but a startup guard should not depend on that.
    function _max_depth()
        return 12
    end function

    ' Every `<name>.bas` under `dir`, at any depth, for the names gdash loads
    ' bare. Returns `{ name, path }` records, deepest-first order unspecified:
    ' the caller reports all of them, since a second one is not less urgent
    ' than the first.
    function shadows_in(dir)
        found = []
        if not gdash_paths.path_exists(dir) then
            return found
        end if
        wanted = guarded_names()
        pending = [{ path: dir, depth: 0 }]
        at = 0
        while at < count(pending)
            here = pending[at]
            at += 1
            on error goto next
            entries = list(here.path)
            if error then
                entries = []
            end if
            for each e in entries
                if e.type = "folder" then
                    if here.depth < _max_depth() then
                        append(pending, { path: e.path, depth: here.depth + 1 })
                    end if
                else
                    for each w in wanted
                        if e.name = w + ".bas" then
                            append(found, { name: w, path: e.path })
                        end if
                    next
                end if
            next
        end while
        return found
    end function

    ' Every name here is gdash's own. `scan`, `check` and `module_dir` were the
    ' first three, and the namespace audit refused all three: gdash_sql,
    ' gdash_record and gdash_paths already define them. A second definition is
    ' harmless under own-library-first resolution and still wrong to leave --
    ' it makes the bare name unwritable for everyone (G1-2).
    function shadows_here()
        return shadows_in(gdash_paths.module_dir())
    end function

    ' The refusal, as text. Separate from the exit so a test can read it and
    ' so the wording lives in one place rather than in four entry points.
    function refusal_text(found)
        if count(found) = 0 then
            return ""
        end if
        out = "gdash: refusing to start -- a file in gdash's own module directory"
        out = out + " shadows a library gdash loads by name." + chr(10)
        for each f in found
            out = out + "  " + f.path + " would be loaded as '" + f.name
            out = out + "' instead of the installed library." + chr(10)
        next
        out = out + "The platform searches the loading file's directory, recursively,"
        out = out + " before the stdlib, and says so only as a warning on stderr." + chr(10)
        out = out + "Move or remove the file, then start gdash again."
        return out
    end function

    ' Called first by every gdash entry point. Fails closed: gdash does not
    ' start, rather than starting with somebody else's crypto.
    function enforce()
        found = shadows_here()
        if count(found) = 0 then
            return 0
        end if
        print to error refusal_text(found)
        exit(2)
        return count(found)
    end function

end library
