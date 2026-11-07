' One visual query over two datasets, for the live-Postgres runner. Both are
' tables in the dashboard's one G-SQL database, so the join needs no attach.
' gbasic takes a FILE, not a program on stdin, so this exists as a file.
program main(args)
    load gdash_store from "../src/gdash_store.bas"
    db = args[0]
    sql = "select r.manager as manager, sum(o.amount) as total from orders o join regions r on r.region = o.region group by r.manager order by 1"
    res = gdash_store.select_rows(db, sql, {})
    if not res.ok then
        print("ERROR " + res.message)
        exit(1)
    end if
    print(string(res.rows[0]["manager"]) + "=" + money.text(res.rows[0]["total"]))
    exit(0)
end program
