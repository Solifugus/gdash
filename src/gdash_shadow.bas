' gdash — the shadowing refusal.
'
' gdash loads nine libraries by bare name, and a bare name does not resolve to
' the installed stdlib first. The platform searches the directory of the SOURCE
' FILE ISSUING THE LOAD before it looks at GBASIC_PATH or the install tree, and
' a file sitting there WINS:
'
'   warning: library 'crypto' resolved to src/crypto.bas;
'            ALSO FOUND and not used: /usr/local/share/gbasic/stdlib/crypto.bas
'
' A service's stderr goes to a log nobody is reading at the moment it matters,
' so that notice is not a control. `crypto` hashes every password and mints
' every session secret; `web` is the server itself. A replacement for either is
' not a bug to be found later.
'
' BESIDE, NOT BELOW -- and this narrowed under us, which is the good kind of
' narrowing. gdash first measured (gbasic 159bc30) that a `chart.bas` THREE
' DIRECTORIES BELOW the loading file also won, silently. That was reported;
' Matthew ruled on it; and as of the rebuild on 2026-09-14 a library below the
' loading file is not used and says so:
'
'   warning: library 'crypto' at src/vendor/deep/crypto.bas was NOT used: it is
'            below the file that loaded it, not beside it.
'
' So this guard reads ONE DIRECTORY and no longer walks. It kept walking for a
' few hours after the platform stopped needing it to, which was not harmless:
' refusing to start over a file the platform will never load is a denial of
' service on a harmless file, and a guard that fires where nothing is wrong is
' how a guard gets switched off.
'
' Every bare-name load in gdash lives in a module under src/ -- the libdir once
' installed -- including the ones in `gdash_server.bas` and the other entry
' PROGRAMS, which sit in that same directory. Measured: a stray beside a
' program that does its own bare load wins too, whatever the working directory
' is. One directory is the whole exposure.
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
        return ["chart", "crypto", "ldap", "llm", "nlq", "odbc", "pg", "sqlite", "web"]
    end function

    ' Every `<name>.bas` sitting IN `dir` -- not below it -- for the names
    ' gdash loads bare. Returns `{ name, path }` records; the caller reports
    ' all of them, since a second one is not less urgent than the first.
    '
    ' A subdirectory is not descended into, because the platform will not load
    ' from one. See the header: this walked, then stopped needing to.
    function shadows_in(dir)
        found = []
        if not gdash_paths.path_exists(dir) then
            return found
        end if
        wanted = guarded_names()
        on error goto next
        entries = list(dir)
        if error then
            return found
        end if
        for each e in entries
            if e.type != "folder" then
                for each w in wanted
                    if e.name = w + ".bas" then
                        append(found, { name: w, path: e.path })
                    end if
                next
            end if
        next
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
        out = out + "The platform searches the loading file's own directory before the"
        out = out + " stdlib, and says so only as a warning on stderr." + chr(10)
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
