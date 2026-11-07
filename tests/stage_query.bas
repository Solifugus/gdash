' For the shell runners: one query against a dashboard's staged G-SQL
' database, read-only, its first column printed comma-joined. Money prints
' through money.text, at its full storage scale, so what a runner compares is
' the exact stored value rather than a display rounding of it.
'
'   stage_query <db> <sql>

program main(args)
    load gdash_store from "../src/gdash_store.bas"
    if count(args) < 2 then
        print to error "usage: stage_query <db> <sql>"
        exit(2)
    end if
    got = gdash_store.select_rows(args[0], args[1], {})
    if not got.ok then
        print to error got.message
        exit(1)
    end if
    out = []
    for each r in got.rows
        v = r[keys(r)[0]]
        if type(v) = "money" then
            out = append(out, money.text(v))
        else
            out = append(out, string(v))
        end if
    next
    print(join(out, ","))
end program
