' The shadowing refusal (GDASH-12 S0-2).
'
' A bare-name `load` does not reach the installed stdlib first. The platform
' searches the loading file's own directory, RECURSIVELY, and the first match
' wins; the real library is reported "ignored" in a stderr warning. Measured
' at gbasic 159bc30, with a chart.bas three directories down beating
' /usr/local/share/gbasic/stdlib/chart.bas.
'
' gdash loads seven libraries that way, two of which are the password hasher
' and the web server, so it looks at that tree before it does anything else.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_shadow from "../src/gdash_shadow.bas"

    s = gdash_test.suite("shadow")
    root = args[0]

    ' --- the list is the seven, and the source agrees with it ---------------
    '
    ' The guard is a hardcoded list, so the list is checked against what gdash
    ' ACTUALLY loads: every `load <name>` in src/ with no `from` clause. A
    ' library added to gdash and not added here is a failure of this test
    ' rather than a hole in the guard that nobody notices.
    src = gdash_paths.module_dir()
    declared = gdash_shadow.guarded_names()

    actual = []
    modules = 0
    for each e in list(src)
        if e.type != "folder" and contains(e.name, ".bas") then
            modules += 1
            mf {file} = e.path
            for each line in split(read(mf), chr(10))
                t = trim(line)
                if len(t) > 5 and mid(t, 0, 5) = "load " and not contains(t, " from ") then
                    nm = trim(mid(t, 5, len(t) - 5))
                    if not contains(actual, nm) then
                        append(actual, nm)
                    end if
                end if
            next
        end if
    next

    ' An empty sweep would agree with any list at all. This is the assertion
    ' that stops the one above from passing vacuously when GDASH_SRC points
    ' somewhere with no gdash in it.
    s = gdash_test.ok(s, modules > 10, "the module sweep found gdash's modules (" + string(modules) + " files in " + src + ")")

    for each nm in actual
        s = gdash_test.ok(s, contains(declared, nm), "src loads '" + nm + "' bare, and the guard knows it")
    next
    for each nm in declared
        s = gdash_test.ok(s, contains(actual, nm), "the guard lists '" + nm + "', and src still loads it")
    next

    ' --- the walk ----------------------------------------------------------
    clean = root + "/clean"
    made = gdash_paths.ensure_dir(clean)
    s = gdash_test.eq(s, count(gdash_shadow.shadows_in(clean)), 0, "a clean module directory is clean")
    s = gdash_test.eq(s, count(gdash_shadow.shadows_in(root + "/nothing-here")), 0, "a missing directory is not an error")

    ' gdash's own modules must not trip it. This is the assertion that would
    ' have caught a guard matching `gdash_*.bas` or every .bas file.
    s = gdash_test.eq(s, count(gdash_shadow.shadows_in(src)), 0, "gdash's real module directory passes")

    ' A stray beside the modules.
    flat = root + "/flat"
    made = gdash_paths.ensure_dir(flat)
    made = write_lib(flat + "/gdash_thing.bas", "gdash_thing")
    made = write_lib(flat + "/notes.bas", "notes")
    s = gdash_test.eq(s, count(gdash_shadow.shadows_in(flat)), 0, "unrelated .bas files are left alone")

    made = write_lib(flat + "/crypto.bas", "crypto")
    hit = gdash_shadow.shadows_in(flat)
    s = gdash_test.eq(s, count(hit), 1, "a crypto.bas beside the modules is caught")
    s = gdash_test.eq(s, at(hit, 0).name, "crypto", "named as the library it would replace")
    s = gdash_test.eq(s, at(hit, 0).path, flat + "/crypto.bas", "and the file that would do it")

    ' Three directories down, which is the shape actually measured.
    deep = root + "/deep"
    made = gdash_paths.ensure_dir(deep + "/a/b/c")
    made = write_lib(deep + "/a/b/c/chart.bas", "chart")
    d = gdash_shadow.shadows_in(deep)
    s = gdash_test.eq(s, count(d), 1, "a chart.bas three directories down is caught")
    s = gdash_test.eq(s, at(d, 0).name, "chart", "named from the nested path")

    ' Two of them: the second is not less urgent than the first.
    made = write_lib(deep + "/web.bas", "web")
    d2 = gdash_shadow.shadows_in(deep)
    s = gdash_test.eq(s, count(d2), 2, "both shadows are reported, not just the first")

    ' A DIRECTORY named crypto.bas cannot be loaded as a library -- the
    ' platform matches regular files only -- so reporting it would be a false
    ' refusal, and a refusal nobody can act on is worse than none.
    dirname = root + "/dirnamed"
    made = gdash_paths.ensure_dir(dirname + "/crypto.bas")
    s = gdash_test.eq(s, count(gdash_shadow.shadows_in(dirname)), 0, "a directory named crypto.bas is not a shadow")

    ' The name must match exactly. `crypto_helpers.bas` does not resolve for
    ' `load crypto`, and neither does `mycrypto.bas`.
    near = root + "/near"
    made = gdash_paths.ensure_dir(near)
    made = write_lib(near + "/crypto_helpers.bas", "crypto_helpers")
    made = write_lib(near + "/mycrypto.bas", "mycrypto")
    made = write_lib(near + "/crypto.bas.txt", "crypto")
    s = gdash_test.eq(s, count(gdash_shadow.shadows_in(near)), 0, "a name that only looks close is not a shadow")

    ' --- what it says ------------------------------------------------------
    s = gdash_test.eq(s, gdash_shadow.refusal_text([]), "", "nothing found says nothing")
    text = gdash_shadow.refusal_text(hit)
    s = gdash_test.contains_text(s, text, "refusing to start", "the refusal says it is refusing")
    s = gdash_test.contains_text(s, text, flat + "/crypto.bas", "and names the file to move")
    s = gdash_test.contains_text(s, text, "'crypto'", "and the library it would have replaced")

    both = gdash_shadow.refusal_text(d2)
    s = gdash_test.contains_text(s, both, "chart", "a two-shadow refusal names the first")
    s = gdash_test.contains_text(s, both, "web", "and the second")

    ' --- module_dir --------------------------------------------------------
    '
    ' The override is how a test program in tests/ can name src/ at all; it is
    ' also how the refresh child is found (G8-2), so the two agree by using
    ' the same variable rather than by being remembered separately.
    s = gdash_test.contains_text(s, src, "src", "module_dir honours GDASH_SRC")

    exit(gdash_test.report(s))
end program

' A short real library, so the fixture files are the thing being guarded
' against rather than empty files that happen to have the name.
function write_lib(path, name)
    f {file} = path
    write(f, "library " + name + chr(10) + "end library" + chr(10))
    return path
end function

' Indexed reads go through this. A count assertion that fails must not then
' CRASH the run on the next line -- that hides every assertion after it, which
' is exactly what happened to the nlq suite and made three mutations look
' caught by nothing at all.
function at(listv, i)
    if i < count(listv) then
        return listv[i]
    end if
    return { name: "(missing)", path: "(missing)" }
end function
