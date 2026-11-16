' GDASH-17 step 0: can a dashboard's database be copied consistently while
' it is in use? gsql.backup, through a connection, against a database a
' second connection holds open and a third writes to during the copy.
'   gbasic tests/measure/backup_probe.bas <scratch-dir>

program main(args)
    load gdash_store from "../../src/gdash_store.bas"

    dir = args[0]
    db = dir + "/live.gsql"
    cols = ["region", "month", "amount"]
    rows = []
    i = 0
    while i < 20000
        rows = append(rows, ["r" + string(mod(i, 7)), "2026-" + string(1 + mod(i, 12)), string(i)])
        i += 1
    end while
    plan = gdash_store.plan_columns(cols, rows, {})
    w = gdash_store.materialize(db, "orders", plan, rows)
    sw = gdash_store.swap(db, "orders")
    print("built: " + string(sw.ok))

    held = gdash_store.connect(db, false)
    t0 = monotonic()
    got = gsql.backup(held, dir + "/copy.gsql")
    print("backup: " + string(got) + " in " + string(round((monotonic() - t0) * 1000, 1)) + " ms")

    ' The live one, written while the copy exists: the copy must not move.
    w2 = gdash_store.materialize(db, "orders", plan, slice(rows, 0, 5))
    sw2 = gdash_store.swap(db, "orders")
    live = gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n
    copy = gdash_store.select_rows(dir + "/copy.gsql", "select count(*) as n from orders", {}).rows[0].n
    print("live after rewrite: " + string(live) + "   copy: " + string(copy))

    ' Refreshing a copy already made keeps what it holds.
    t1 = monotonic()
    again = gsql.backup(held, dir + "/copy.gsql")
    print("refresh into copy: " + string(again) + " in " + string(round((monotonic() - t1) * 1000, 1)) + " ms")
    gsql.close(held)
end program
