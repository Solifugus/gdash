' Where a refresh's time goes, phase by phase (GDASH-16 step 0).
program main(args)
    load pg
    load gsql
    n = number(args[0])
    db = args[1]
    prof = { host: default(env("GDASH_PG_HOST"), "127.0.0.1"), port: number(default(env("GDASH_PG_PORT"), "5432")), database: default(env("GDASH_PG_DB"), "gdash_test"), user: env("GDASH_PG_USER"), password: env("GDASH_PG_PASSWORD") }
    conn = pg.connect(prof)
    t0 = monotonic()
    rows = pg.query(conn, "select g as id, 'region-' || (g % 50) as region, 'product-' || (g % 997) as product, (g * 1.37)::numeric(12,2) as amount, (g % 13) as qty, md5(g::text) as ref, g * 0.5 as ratio, 'note for row ' || g as note from generate_series(1, " + string(n) + ") g")
    t1 = monotonic()
    cols = keys(rows[0])
    out = []
    for each r in rows
        vals = []
        for each c in cols
            vals = append(vals, string(r[c]))
        next
        out = append(out, vals)
    next
    t2 = monotonic()
    g = gsql.connect(db, { create: true, linger: 0 })
    gsql.exec(g, "create table m (id integer, region string, product string, amount money(USD), qty integer, ref string, ratio number, note string)")
    t3 = monotonic()
    i = 0
    built = 0
    ins = 0
    while i < n
        a = monotonic()
        batch = []
        k = i
        while k < i + 1000 and k < n
            rec = {}
            c = 0
            while c < count(cols)
                rec[cols[c]] = out[k][c]
                c += 1
            end while
            batch = append(batch, rec)
            k += 1
        end while
        b = monotonic()
        gsql.insert(g, "m", batch)
        built += b - a
        ins += monotonic() - b
        i += 1000
    end while
    print("query=" + string(round(t1 - t0, 2)) + " convert=" + string(round(t2 - t1, 2)) + " build=" + string(round(built, 2)) + " insert=" + string(round(ins, 2)))
end program
