program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_record from "../src/gdash_record.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"
    load gdash_render from "../src/gdash_render.bas"

    s = gdash_test.suite("render")
    root = args[0]
    p = gdash_paths.roles(root)

    rec = gdash_record.load_file("dashboards/sales/draft.json").record
    r = gdash_refresh.run(p, "sales", "draft", rec, "orders", { kind: "fixture", path: "fixtures/orders.json" }, "manual")
    s = gdash_test.ok(s, r.ok, "dataset refreshed for rendering -- " + r.message)
    live = gdash_paths.dataset_db(p, "sales", "draft", "orders")

    ' Currency formatting itself is pinned in test_format; what matters
    ' here is that a visual renders THROUGH it.
    s = gdash_test.eq(s, gdash_render.money_scale(live, {}), 2, "scale read from the dataset")

    ' --- the value mark ---
    gt = rec["visuals"]["grand_total"]
    s = gdash_test.eq(s, string(gdash_render.exact_columns(gt)), string(["total"]), "currency channel crosses exactly")
    res = gdash_store.select_rows(live, gt["sql"], {}, gdash_render.exact_columns(gt), {})
    s = gdash_test.ok(s, res.ok, "value query runs")
    frag = gdash_render.render_visual("grand_total", gt, res.rows, live, {})
    s = gdash_test.contains_text(s, frag, "gdash-value", "value mark renders a value fragment")
    ' 1250.75+900.25+1100.00+640.10+725.90+310.05 = 4927.05
    s = gdash_test.contains_text(s, frag, "$4,927.05", "value mark shows the exact total")

    ' --- the bar mark, a DIFFERENT render path off the same record shape ---
    bm = rec["visuals"]["by_month"]
    s = gdash_test.eq(s, string(gdash_render.exact_columns(bm)), string(["total"]), "bar's y channel crosses exactly")
    bres = gdash_store.select_rows(live, bm["sql"], { region: "west" }, gdash_render.exact_columns(bm), {})
    s = gdash_test.ok(s, bres.ok, "bar query runs")
    bfrag = gdash_render.render_visual("by_month", bm, bres.rows, live, {})
    s = gdash_test.contains_text(s, bfrag, "<svg", "bar mark renders SVG")
    s = gdash_test.ok(s, not contains(bfrag, "gdash-error"), "bar mark rendered without error")
    ' Two marks, two fragment kinds, from one record shape: the dispatch is real.
    s = gdash_test.ok(s, not contains(frag, "<svg"), "value and bar produce different fragment kinds")

    ' The param actually filtered: west has 3 months, and a different region
    ' gives a different chart.
    s = gdash_test.eq(s, count(bres.rows), 3, "west has three months")
    nres = gdash_store.select_rows(live, bm["sql"], { region: "north" }, gdash_render.exact_columns(bm), {})
    s = gdash_test.eq(s, count(nres.rows), 1, "north has one month")
    nfrag = gdash_render.render_visual("by_month", bm, nres.rows, live, {})
    s = gdash_test.ok(s, nfrag != bfrag, "a different param value renders a different chart")

    ' --- channel validation at query time, the F4 fallback ---
    broken = { dataset: "orders", sql: "select month as month, sum(amount) as total from orders group by month", encoding: { mark: "bar", x: "month", y: "ghost", format: "currency" } }
    bres2 = gdash_store.select_rows(live, broken["sql"], {}, [], {})
    bad = gdash_render.render_visual("broken", broken, bres2.rows, live, {})
    s = gdash_test.contains_text(s, bad, "gdash-error", "a channel naming no column is refused")
    s = gdash_test.contains_text(s, bad, "which the query does not return", "and says what is wrong")

    ' --- empty result is not an error ---
    eres = gdash_store.select_rows(live, bm["sql"], { region: "nowhere" }, gdash_render.exact_columns(bm), {})
    s = gdash_test.contains_text(s, gdash_render.render_visual("by_month", bm, eres.rows, live, {}), "No data", "empty result renders as empty, not broken")

    ' --- markup is escaped, not interpolated ---
    ctl = rec["controls"]["region_picker"]
    html = gdash_render.render_control("region_picker", ctl, ["west", "<script>x</script>"], "west")
    s = gdash_test.contains_text(s, html, "&lt;script&gt;", "option text is escaped")
    s = gdash_test.ok(s, not contains(html, "<script>"), "no raw script tag survives")
    s = gdash_test.contains_text(s, html, "selected", "current value is selected")

    exit(gdash_test.report(s))
end program
