' One visual query over two dataset files, for the live-Postgres runner.
' gbasic takes a FILE, not a program on stdin, so this exists as a file.
program main(args)
    load gdash_store from "../src/gdash_store.bas"
    dir = args[0]
    sql = "select r.manager as manager, sum(o.amount) as total from orders o join regions r on r.region = o.region group by r.manager order by 1"
    res = gdash_store.select_rows(dir + "/orders.db", sql, {}, ["total"], { regions: dir + "/regions.db" })
    if not res.ok then
        print("ERROR " + res.message)
        exit(1)
    end if
    print(string(res.rows[0]["manager"]) + "=" + string(res.rows[0]["total__text"]))
    exit(0)
end program
