program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_record from "../src/gdash_record.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"
    load gdash_render from "../src/gdash_render.bas"

    s = gdash_test.suite("marks")
    root = args[0]
    p = gdash_paths.roles(root)
    rec = gdash_record.load_file("dashboards/sales/draft.json").record
    r = gdash_refresh.run(p, "sales", "draft", rec, "orders", { kind: "fixture", path: "fixtures/orders.json" }, "manual")
    s = gdash_test.ok(s, r.ok, "dataset refreshed -- " + r.message)
    live = gdash_paths.dataset_db(p, "sales", "draft", "orders")

    ' --- series: one query fans out into one chart series per value ---
    sq = "select month as month, region as region, sum(amount) as total from orders group by month, region order by month, region"
    v = { dataset: "orders", sql: sq, encoding: { mark: "line", x: "month", y: "total", series: "region", format: "currency" } }
    res = gdash_store.select_rows(live, sq, {}, gdash_render.exact_columns(v), {})
    s = gdash_test.ok(s, res.ok, "series query runs")
    frag = gdash_render.render_visual("trend", v, res.rows, live, {})
    s = gdash_test.contains_text(s, frag, "<svg", "line mark renders SVG")
    s = gdash_test.ok(s, not contains(frag, "gdash-error"), "line rendered without error -- " + mid(frag, 0, 120))

    ' The fixture has three regions; the pivot must produce three series, and
    ' a month a region has no row for must be a GAP, not a zero.
    piv = gdash_render._pivot(res.rows, "month", "total", "region", true, 2)
    s = gdash_test.eq(s, count(piv.names), 3, "three regions become three series")
    s = gdash_test.eq(s, string(piv.names), string(["east", "north", "west"]), "series in result order")
    s = gdash_test.eq(s, count(piv.xs), 3, "three distinct months on x")
    ' north appears only in 2026-01, so its other two slots are gaps.
    north = piv.df["north"]
    s = gdash_test.ok(s, is_unknown(north[1]), "a missing (x, series) pair is a gap, not zero")
    s = gdash_test.ok(s, not is_unknown(north[0]), "and the pair that exists has a value")

    ' bar takes the same series channel off the same record shape
    vb = { dataset: "orders", sql: sq, encoding: { mark: "bar", x: "month", y: "total", series: "region", format: "currency" } }
    bfrag = gdash_render.render_visual("trendbar", vb, res.rows, live, {})
    s = gdash_test.contains_text(s, bfrag, "<svg", "bar renders with series too")
    s = gdash_test.ok(s, bfrag != frag, "bar and line are different renders")

    ' a series channel naming no column is refused
    vbad = { dataset: "orders", sql: sq, encoding: { mark: "line", x: "month", y: "total", series: "ghost" } }
    s = gdash_test.contains_text(s, gdash_render.render_visual("x", vbad, res.rows, live, {}), "which the query does not return", "bad series channel refused")

    ' --- table: SELECT order, per-column formats ---
    tq = "select region as region, month as month, sum(amount) as total from orders group by region, month order by region, month"
    vt = { dataset: "orders", sql: tq, encoding: { mark: "table", title: "Detail", formats: { total: "currency" } } }
    tres = gdash_store.select_rows(live, tq, {}, gdash_render.exact_columns(vt), {})
    s = gdash_test.eq(s, string(gdash_render.exact_columns(vt)), string(["total"]), "currency column crosses exactly")
    tfrag = gdash_render.render_visual("detail", vt, tres.rows, live, {})
    s = gdash_test.contains_text(s, tfrag, "<table>", "table mark renders a table")
    s = gdash_test.contains_text(s, tfrag, "$1,250.75", "money column formatted as currency")
    ' SELECT order preserved, and the exactness helper column is not shown
    s = gdash_test.ok(s, not contains(tfrag, "total__text"), "the __text helper column is not rendered")
    heads = mid(tfrag, find(tfrag, "<thead>"), 90)
    s = gdash_test.ok(s, find(heads, "region") < find(heads, "month"), "columns in SELECT order (region before month)")
    s = gdash_test.ok(s, find(heads, "month") < find(heads, "total"), "columns in SELECT order (month before total)")

    ' formats accept the long form with options
    vt2 = { dataset: "orders", sql: tq, encoding: { mark: "table", formats: { total: { name: "number", decimals: 0 } } } }
    t2 = gdash_render.render_visual("d2", vt2, tres.rows, live, {})
    s = gdash_test.ok(s, not contains(t2, "$"), "number format is not currency")

    ' an unformatted column renders as its raw text
    s = gdash_test.contains_text(s, tfrag, "west", "unformatted column passes through")

    exit(gdash_test.report(s))
end program
