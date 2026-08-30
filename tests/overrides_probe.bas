' The library-namespace sweep.
'
' gBASIC has no library namespaces: a function name is global, and a second
' library defining a name that already exists silently OVERRIDES it, warning
' only on stderr (finding F6). GDASH-0 lost an afternoon to
' gdash_paths.resolve shadowing web.resolve, and GDASH-1 repeated it within a
' day of writing the finding down (G1-2), so the check is automated rather
' than remembered.
'
' This program loads every gdash module together with every stdlib library
' gdash touches. The runner fails the suite if the interpreter says anything
' about an override. It asserts nothing itself; its stderr IS the assertion.

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
    load gdash_app from "../src/gdash_app.bas"
    load gdash_source_fixture from "../src/gdash_source_fixture.bas"

    print("loaded " + string(count(keys(gdash_paths.roles("/x")))) + " path roles")
    exit(0)
end program
