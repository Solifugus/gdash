' Two datasets, one visual query, no schema prefix anywhere.
'
' Design §3 gets cross-source joins for free: two datasets land in the same
' local store and a visual query joins them. Finding G2-2 made it better than
' the design assumed -- unqualified table names resolve across every dataset
' of a dashboard (since GDASH-20, tables in one database), so the SQL an
' author writes over two datasets is the same SQL they write over one.

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

    ' Both datasets are tables in the dashboard's ONE database (GDASH-20), so
    ' a cross-dataset join needs no attach, no prefix and no cap.
    db = gdash_paths.stage_db(p, "sales", "draft")
    s = gdash_test.ok(s, gdash_store.has_dataset(db, "orders") and gdash_store.has_dataset(db, "regions"), "both datasets are tables in one database")

    v = rec["visuals"]["by_manager"]
    res = gdash_store.select_rows(db, v["sql"], {})
    s = gdash_test.ok(s, res.ok, "the cross-dataset query runs -- " + res.message)
    s = gdash_test.eq(s, count(res.rows), 2, "two managers")

    ' west 3251.00 + north 310.05 = 3561.05 for Ada; east 1366.00 for Bo.
    s = gdash_test.eq(s, res.rows[0]["manager"], "Ada Okonjo", "grouped by a column that lives in the OTHER dataset")
    s = gdash_test.eq(s, money.text(res.rows[0]["total"], 2), "3561.05", "summed exactly across the join")

    ' The money scale comes from the dataset that HAS the money column; the
    ' other one, with none, contributes nothing to disagree with.
    s = gdash_test.eq(s, gdash_render.money_scale(db), 2, "the money scale is the orders column's")

    frag = gdash_render.render_visual("by_manager", v, res.rows, db, {})
    s = gdash_test.contains_text(s, frag, "Ada Okonjo", "the fragment names a value only the second dataset knows")
    s = gdash_test.contains_text(s, frag, "<svg", "and it is a chart")

    ' Either dataset can lead the join: neither is "main" any more.
    back = gdash_store.select_rows(db, "select o.region as region, sum(o.amount) as total from regions r join orders o on r.region = o.region group by o.region order by 1", {})
    s = gdash_test.ok(s, back.ok, "the join runs with the roles reversed")

    exit(gdash_test.report(s))
end program
