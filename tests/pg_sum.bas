' Helper for the live-Postgres runner: read one exact money total back out of
' a refreshed dashboard's G-SQL database. Kept as a file rather than piped to
' the interpreter because gbasic takes a FILE argument and has no stdin form.
' The total prints through money.text, at its full storage scale, so what the
' runner compares is the exact stored value.
'
'   pg_sum.bas <data.gsql> <region|*>

program main(args)
    load gdash_store from "../src/gdash_store.bas"

    db = args[0]
    region = args[1]
    if region = "*" then
        r = gdash_store.select_rows(db, "select sum(amount) as total from orders", {})
    else
        r = gdash_store.select_rows(db, "select sum(amount) as total from orders where region = :region", { region: region })
    end if
    if not r.ok then
        print to error "query failed: " + r.message
        exit(1)
    end if
    if count(r.rows) = 0 then
        print to error "no rows"
        exit(1)
    end if
    print(money.text(r.rows[0]["total"]))
end program
