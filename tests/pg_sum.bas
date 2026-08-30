' Helper for the live-Postgres runner: read one exact money total back out of
' a refreshed dataset file. Kept as a file rather than piped to the
' interpreter because gbasic takes a FILE argument and has no stdin form.
'
'   pg_sum.bas <dataset.db> <region|*>

program main(args)
    load gdash_store from "../src/gdash_store.bas"

    db = args[0]
    region = args[1]
    if region = "*" then
        r = gdash_store.select_rows(db, "select sum(amount) as total from orders", {}, ["total"], {})
    else
        r = gdash_store.select_rows(db, "select sum(amount) as total from orders where region = :region", { region: region }, ["total"], {})
    end if
    if not r.ok then
        print to error "query failed: " + r.message
        exit(1)
    end if
    if count(r.rows) = 0 then
        print to error "no rows"
        exit(1)
    end if
    print(r.rows[0]["total__text"])
end program
