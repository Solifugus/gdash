' Two datasets, one visual query, no schema prefix anywhere.
'
' Design §3 gets cross-source joins for free: two datasets land in the same
' local store and a visual query joins them. Finding G2-2 made it better than
' the design assumed -- unqualified table names resolve across attached
' schemas, so the SQL an author writes over two datasets is the same SQL they
' write over one.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_record from "../src/gdash_record.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_render from "../src/gdash_render.bas"

    s = gdash_test.suite("multi")
    root = args[0]
    p = gdash_paths.roles(root)

    rec = gdash_record.load_file("dashboards/sales/draft.json").record
    r1 = gdash_refresh.run(p, "sales", "draft", rec, "orders", { kind: "fixture", path: "fixtures/orders.json" }, "manual")
    s = gdash_test.ok(s, r1.ok, "orders refreshed -- " + r1.message)
    r2 = gdash_refresh.run(p, "sales", "draft", rec, "regions", { kind: "fixture", path: "fixtures/regions.json" }, "manual")
    s = gdash_test.ok(s, r2.ok, "regions refreshed -- " + r2.message)

    ' Each dataset is its own SQLite file: the swap stays a single rename.
    ordersdb = gdash_paths.dataset_db(p, "sales", "draft", "orders")
    regionsdb = gdash_paths.dataset_db(p, "sales", "draft", "regions")
    s = gdash_test.ok(s, ordersdb != regionsdb, "each dataset is its own file")
    s = gdash_test.ok(s, gdash_paths.path_exists(regionsdb), "the second dataset file exists")

    v = rec["visuals"]["by_manager"]
    attach = { regions: regionsdb }
    res = gdash_store.select_rows(ordersdb, v["sql"], {}, gdash_render.exact_columns(v), attach)
    s = gdash_test.ok(s, res.ok, "the cross-dataset query runs -- " + res.message)
    s = gdash_test.eq(s, count(res.rows), 2, "two managers")

    ' west 3251.00 + north 310.05 = 3561.05 for Ada; east 1366.00 for Bo.
    s = gdash_test.eq(s, res.rows[0]["manager"], "Ada Okonjo", "grouped by a column that lives in the OTHER dataset")
    s = gdash_test.eq(s, res.rows[0]["total__text"], "356105", "summed exactly across the join")

    ' The money scale must come from the dataset that HAS the money column.
    ' An unqualified _gdash_meta read would answer from whichever file is
    ' `main` -- silently, and only when there are two datasets (finding G2-3).
    s = gdash_test.eq(s, gdash_render.money_scale(ordersdb, attach), 2, "the money scale survives the attachment")

    frag = gdash_render.render_visual("by_manager", v, res.rows, ordersdb, attach)
    s = gdash_test.contains_text(s, frag, "Ada Okonjo", "the fragment names a value only the second dataset knows")
    s = gdash_test.contains_text(s, frag, "<svg", "and it is a chart")

    ' Reversing the roles: the regions file as `main`, orders attached. The
    ' scale must still be the orders column's, not absent.
    back = gdash_store.select_rows(regionsdb, "select o.region as region, sum(o.amount) as total from orders o join regions r on r.region = o.region group by o.region order by 1", {}, ["total"], { orders: ordersdb })
    s = gdash_test.ok(s, back.ok, "the join runs with the roles reversed")
    s = gdash_test.eq(s, gdash_render.money_scale(regionsdb, { orders: ordersdb }), 2, "the attached dataset's scale is found when main has none")

    ' Without the attachment the query fails rather than quietly returning
    ' nothing, which is what surfaces as a per-visual error on the page.
    lone = gdash_store.select_rows(ordersdb, v["sql"], {}, [], {})
    s = gdash_test.ok(s, not lone.ok, "the same query fails with nothing attached")

    exit(gdash_test.report(s))
end program
