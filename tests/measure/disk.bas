' Whether a G-SQL database gives space back when a dataset is swapped
' (GDASH-16 step 0): the quota is only as good as what du sees.
program main(args)
    load gsql
    db = args[0]
    function du(dir)
        total = 0
        for each e in list(dir)
            if e.type = "folder" then
                total += du(e.path)
            else
                total += default(e.size, 0)
            end if
        next
        return total
    end function
    g = gsql.connect(db, { create: true, linger: 0 })
    rows = []
    for i = 1 to 20000
        rows = append(rows, { id: i, note: "note for row " + string(i) + " padded padded padded" })
    next
    for round_n = 1 to number(default(args[1], "4"))
        gsql.exec(g, "drop table if exists s")
        gsql.exec(g, "create table s (id integer, note string)")
        k = 0
        while k < 20000
            gsql.insert(g, "s", slice(rows, k, 1000))
            k += 1000
        end while
        gsql.begin(g)
        gsql.exec(g, "drop table if exists live")
        gsql.exec(g, "alter table s rename to live")
        gsql.commit(g)
        print("swap " + string(round_n) + ": " + string(du(db)) + " bytes")
    next
    t = monotonic()
    n = du(db)
    print("du took " + string(round((monotonic() - t) * 1000, 1)) + " ms over " + string(count(list(db))) + " entries")
end program
