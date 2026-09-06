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
    '
    ' THIS BLOCK USED TO ASSERT "<svg" AND NOTHING ELSE, and it passed for six
    ' phases while the chart was blank: an empty frame is still an SVG, with
    ' axes, gridlines and labels (finding G7-3). The assertion now names the
    ' element that only appears when data was actually drawn.
    sq = "select month as month, region as region, sum(amount) as total from orders group by month, region order by month, region"
    v = { dataset: "orders", sql: sq, encoding: { mark: "bar", x: "month", y: "total", series: "region", format: "currency" } }
    res = gdash_store.select_rows(live, sq, {}, gdash_render.exact_columns(v), {})
    s = gdash_test.ok(s, res.ok, "series query runs")
    frag = gdash_render.render_visual("trend", v, res.rows, live, {})
    s = gdash_test.contains_text(s, frag, "<svg", "a series bar renders SVG")
    s = gdash_test.ok(s, not contains(frag, "gdash-error"), "without error -- " + mid(frag, 0, 120))
    s = gdash_test.ok(s, count(split(frag, "<rect")) - 1 > 1, "with a bar per series value, not an empty frame")

    ' A line needs a numeric x, and draws a path when it has one.
    nq = "select cast(substr(month, 6, 2) as integer) as period, sum(amount) as total from orders group by period order by period"
    nv = { dataset: "orders", sql: nq, encoding: { mark: "line", x: "period", y: "total", format: "currency" } }
    nres = gdash_store.select_rows(live, nq, {}, gdash_render.exact_columns(nv), {})
    nfrag = gdash_render.render_visual("trend_num", nv, nres.rows, live, {})
    s = gdash_test.ok(s, not contains(nfrag, "gdash-error"), "a line over a numeric x renders -- " + mid(nfrag, 0, 120))
    s = gdash_test.eq(s, count(split(nfrag, "<path")) - 1, 1, "and draws exactly one path, which is the line")

    ' ...and refuses, by name, when the x is text. Loud beats an empty chart:
    ' the viewer would read a blank plot as "no data" and the author as
    ' "working".
    cv = { dataset: "orders", sql: sq, encoding: { mark: "line", x: "month", y: "total", series: "region", format: "currency" } }
    cfrag = gdash_render.render_visual("trend", cv, res.rows, live, {})
    s = gdash_test.contains_text(s, cfrag, "gdash-error", "a line over a text x is refused")
    s = gdash_test.contains_text(s, cfrag, "column 'month' holds text", "naming the column")
    s = gdash_test.contains_text(s, cfrag, "mark 'bar' for categories", "and what to do instead")
    s = gdash_test.eq(s, count(split(cfrag, "<svg")) - 1, 0, "with no chart at all, rather than an empty one")

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

    ' Dropping the series channel collapses the fan-out, so the same query
    ' renders fewer bars. Asserted on the COUNT rather than on inequality: two
    ' renders differing somewhere is a weaker claim than one having the bars
    ' the other's series produced.
    vb = { dataset: "orders", sql: sq, encoding: { mark: "bar", x: "month", y: "total", format: "currency" } }
    bfrag = gdash_render.render_visual("trendbar", vb, res.rows, live, {})
    s = gdash_test.contains_text(s, bfrag, "<svg", "bar renders without a series channel too")
    s = gdash_test.ok(s, (count(split(bfrag, "<rect")) - 1) < (count(split(frag, "<rect")) - 1), "and draws fewer bars than the same query fanned out by series")

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
