' The namespace audit.
'
' gBASIC has no library namespaces: a function name is global, and a second
' library defining a name that already exists silently overrides it (F6).
' GDASH-0 lost an afternoon to gdash_paths.resolve shadowing web.resolve, and
' GDASH-1 repeated it within a day of writing the finding down (G1-2), so the
' check is automated rather than remembered.
'
' It is checked TWO ways, because one of them is not enough:
'
'   library_collisions() reports every public name defined by more than one
'   loaded library -- the LATENT state, before anyone writes the call that
'   makes it live. This is the real audit, and it exists because gdash asked:
'   the override warning is call-triggered, so two libraries sharing a name
'   stay silent for as long as every call is qualified (G4-6). A sweep resting
'   on the warning alone is a partial check.
'
'   The warning still catches what the audit does not: a library function
'   shadowing a BUILT-IN. That is how gdash_diff.lines was caught (G3-1). The
'   runner reads stderr for it.
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
