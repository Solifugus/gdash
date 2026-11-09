' The dataset-size ceiling, measured (GDASH-16). One refresh child's work --
' fetch from Postgres, plan, materialize into G-SQL -- for N rows of a
' ten-column shape, so the peak RSS per row can be read off a few runs. The
' profile comes from the environment; nothing is written but the scratch db.

program main(args)
    load gdash_source_pg from "../../src/gdash_source_pg.bas"
    load gdash_store from "../../src/gdash_store.bas"

    n = number(args[0])
    db = args[1]
    prof = { kind: "postgres", host: default(env("GDASH_PG_HOST"), "127.0.0.1"), port: number(default(env("GDASH_PG_PORT"), "5432")),
             database: default(env("GDASH_PG_DB"), "gdash_test"), user: env("GDASH_PG_USER"), password: env("GDASH_PG_PASSWORD") }
    sql = "select g as id, 'region-' || (g % 50) as region, 'product-' || (g % 997) as product, (g * 1.37)::numeric(12,2) as amount, (g % 13) as qty, date '2026-01-01' + (g % 365) as day, md5(g::text) as ref, (g % 2 = 0) as flag, g * 0.5 as ratio, 'note for row ' || g as note from generate_series(1, " + string(n) + ") g"
    t0 = monotonic()
    got = gdash_source_pg.fetch(prof, sql, 0)
    if not got.ok then
        print to error got.message
        exit(1)
    end if
    t1 = monotonic()
    plan = gdash_store.plan_columns(got.columns, got.rows, { amount: { type: "money", scale: 2 }, day: { type: "date" } })
    wrote = gdash_store.materialize(db, "m", plan, got.rows)
    if not wrote.ok then
        print to error wrote.message
        exit(2)
    end if
    t2 = monotonic()
    print("rows=" + string(count(got.rows)) + " fetch_s=" + string(round(t1 - t0, 2)) + " write_s=" + string(round(t2 - t1, 2)))
end program
