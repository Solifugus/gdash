' The namespace audit.
'
' gBASIC has no library namespaces: a function name is global, and a second
' library defining a name that already exists silently overrides it (F6).
' GDASH-0 lost an afternoon to gdash_paths.resolve shadowing web.resolve, and
' GDASH-1 repeated it within a day of writing the finding down (G1-2), so the
' check is automated rather than remembered.
'
' The hazard itself is now gone from the platform: since gbasic d08409f a
' library's own unqualified calls resolve to its own functions first, so no
' library can capture another's internals (G4-12). What remains is ambiguity
' for a CALLER writing a bare name outside every library that defines it, and
' that is still worth refusing.
'
' Checked two ways, because neither covers the other:
'
'   library_collisions() reports every public name defined by more than one
'   loaded library. Two libraries sharing a name is now silent -- correctly,
'   since neither is harmed -- so this audit is the only thing that sees it.
'
'   stderr carries the note for a library function shadowing a BUILT-IN, which
'   the audit does not cover. That one still matters inside gdash: sixteen
'   modules call each other, and a gdash function named like a built-in is a
'   function every OTHER gdash module reaches past. It is a `note` on the
'   platform, because there the rule is well-defined; it is a failure here,
'   because here it is a name collision across our own modules.
'
' Some collisions are legitimate and belong in `accepted` with a reason. An
' empty list is not the goal; an explained list is.

program main(args)
    load web
    load sqlite
    load crypto
    load chart from "../../gbasic/stdlib/chart.bas"

    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_sql from "../src/gdash_sql.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_format from "../src/gdash_format.bas"
    load gdash_record from "../src/gdash_record.bas"
    load gdash_render from "../src/gdash_render.bas"
    load gdash_sched from "../src/gdash_sched.bas"
    load gdash_audit from "../src/gdash_audit.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"
    load gdash_publish from "../src/gdash_publish.bas"
    load gdash_diff from "../src/gdash_diff.bas"
    load gdash_app from "../src/gdash_app.bas"
    load gdash_session from "../src/gdash_session.bas"
    load gdash_session_files from "../src/gdash_session_files.bas"
    load gdash_users from "../src/gdash_users.bas"
    load gdash_source_fixture from "../src/gdash_source_fixture.bas"

    ' Nothing yet. When a name lands here it needs a sentence saying why the
    ' collision is harmless -- which in practice means: no library involved
    ' ever calls it unqualified, and gdash never will either.
    accepted = []

    bad = 0
    for each c in library_collisions()
        if not contains(accepted, c.name) then
            print to error "namespace: '" + c.name + "' is defined by " + join(c.libraries, " and ")
            bad += 1
        end if
    next

    if bad > 0 then
        print to error "a name defined twice is a name one of them silently wins"
        exit(1)
    end if
    print("no unaccepted library name collisions across gdash and the stdlib it loads")
    exit(0)
end program
