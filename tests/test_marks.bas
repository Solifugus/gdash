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
    frag = gdash_render.render_visual("trend", v, res.rows, live, {}, {})
    s = gdash_test.contains_text(s, frag, "<svg", "a series bar renders SVG")
    s = gdash_test.ok(s, not contains(frag, "gdash-error"), "without error -- " + mid(frag, 0, 120))
    s = gdash_test.ok(s, count(split(frag, "<rect")) - 1 > 1, "with a bar per series value, not an empty frame")

    ' A line needs a numeric x, and draws a path when it has one.
    nq = "select cast(substr(month, 6, 2) as integer) as period, sum(amount) as total from orders group by period order by period"
    nv = { dataset: "orders", sql: nq, encoding: { mark: "line", x: "period", y: "total", format: "currency" } }
    nres = gdash_store.select_rows(live, nq, {}, gdash_render.exact_columns(nv), {})
    nfrag = gdash_render.render_visual("trend_num", nv, nres.rows, live, {}, {})
    s = gdash_test.ok(s, not contains(nfrag, "gdash-error"), "a line over a numeric x renders -- " + mid(nfrag, 0, 120))
    s = gdash_test.eq(s, count(split(nfrag, "<path")) - 1, 1, "and draws exactly one path, which is the line")

    ' ...and a text x is now ORDINAL rather than refused. gdash carried a
    ' refusal here from GDASH-7 until gbasic a1f6da5 gave line, area and
    ' scatter the same band centres `bar` uses; the refusal is gone and this
    ' is what replaced it.
    cv = { dataset: "orders", sql: sq, encoding: { mark: "line", x: "month", y: "total", series: "region", format: "currency" } }
    cfrag = gdash_render.render_visual("trend", cv, res.rows, live, {}, {})
    s = gdash_test.ok(s, not contains(cfrag, "gdash-error"), "a line over a text x renders -- " + mid(cfrag, 0, 110))
    s = gdash_test.ok(s, count(split(cfrag, "<path")) - 1 > 0, "and draws a line, which is the whole point")

    ' THE ALIGNMENT CLAIM, checked from gdash's side. A line and a bar of the
    ' same frame put their marks on the same x positions -- if they did not,
    ' a dashboard showing both would misread.
    bfrag2 = gdash_render.render_visual("trend", { dataset: "orders", sql: sq, encoding: { mark: "bar", x: "month", y: "total", series: "region", format: "currency" } }, res.rows, live, {}, {})
    s = gdash_test.contains_text(s, cfrag, ">2026-01<", "the line labels the categories")
    s = gdash_test.contains_text(s, bfrag2, ">2026-01<", "and so does the bar")


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
    ' Its own query: dropping the series channel from a (month, region)
    ' aggregate leaves two rows per month, which gdash now refuses rather than
    ' silently keeping one of them.
    mq = "select month as month, sum(amount) as total from orders group by month order by month"
    mres = gdash_store.select_rows(live, mq, {}, gdash_render.exact_columns({ encoding: { mark: "bar", x: "month", y: "total", format: "currency" } }), {})
    vb = { dataset: "orders", sql: mq, encoding: { mark: "bar", x: "month", y: "total", format: "currency" } }
    bfrag = gdash_render.render_visual("trendbar", vb, mres.rows, live, {}, {})
    s = gdash_test.contains_text(s, bfrag, "<svg", "bar renders without a series channel too")
    s = gdash_test.ok(s, (count(split(bfrag, "<rect")) - 1) < (count(split(frag, "<rect")) - 1), "and draws fewer bars than the same query fanned out by series")

    ' a series channel naming no column is refused
    vbad = { dataset: "orders", sql: sq, encoding: { mark: "line", x: "month", y: "total", series: "ghost" } }
    s = gdash_test.contains_text(s, gdash_render.render_visual("x", vbad, res.rows, live, {}, {}), "which the query does not return", "bad series channel refused")

    ' --- table: SELECT order, per-column formats ---
    tq = "select region as region, month as month, sum(amount) as total from orders group by region, month order by region, month"
    vt = { dataset: "orders", sql: tq, encoding: { mark: "table", title: "Detail", formats: { total: "currency" } } }
    tres = gdash_store.select_rows(live, tq, {}, gdash_render.exact_columns(vt), {})
    s = gdash_test.eq(s, string(gdash_render.exact_columns(vt)), string(["total"]), "currency column crosses exactly")
    tfrag = gdash_render.render_visual("detail", vt, tres.rows, live, {}, {})
    s = gdash_test.contains_text(s, tfrag, "<table>", "table mark renders a table")
    s = gdash_test.contains_text(s, tfrag, "$1,250.75", "money column formatted as currency")
    ' SELECT order preserved, and the exactness helper column is not shown
    s = gdash_test.ok(s, not contains(tfrag, "total__text"), "the __text helper column is not rendered")
    heads = mid(tfrag, find(tfrag, "<thead>"), 90)
    s = gdash_test.ok(s, find(heads, "region") < find(heads, "month"), "columns in SELECT order (region before month)")
    s = gdash_test.ok(s, find(heads, "month") < find(heads, "total"), "columns in SELECT order (month before total)")

    ' formats accept the long form with options
    vt2 = { dataset: "orders", sql: tq, encoding: { mark: "table", formats: { total: { name: "number", decimals: 0 } } } }
    t2 = gdash_render.render_visual("d2", vt2, tres.rows, live, {}, {})
    s = gdash_test.ok(s, not contains(t2, "$"), "number format is not currency")

    ' an unformatted column renders as its raw text
    s = gdash_test.contains_text(s, tfrag, "west", "unformatted column passes through")

    ' --- chart options reach the SVG (GDASH-7 §2.2) ----------------------
    '
    ' Each option is asserted by rendering WITH IT AND WITHOUT IT and requiring
    ' the difference the option names. Asserting that a string is present would
    ' pass for a stylesheet, an empty frame, or a title that happened to repeat
    ' elsewhere -- which is how a line chart stayed blank for six phases
    ' (G7-3), and what GDASH-6's audit was about.
    num_rows = [ { m: 1, amt: 10.0 }, { m: 2, amt: 40.0 }, { m: 3, amt: 25.0 } ]
    ser_rows = [ { m: 1, r: "north", amt: 10.0 }, { m: 1, r: "south", amt: 5.0 },
                 { m: 2, r: "north", amt: 40.0 }, { m: 2, r: "south", amt: 20.0 } ]

    plain = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "line", x: "m", y: "amt" } }, num_rows, "", {}, {})
    labelled = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "line", x: "m", y: "amt", title: "Revenue", x_label: "Period", y_label: "Dollars" } }, num_rows, "", {}, {})
    s = gdash_test.ok(s, not contains(plain, ">Revenue<"), "a chart with no title carries none")
    s = gdash_test.contains_text(s, labelled, ">Revenue<", "a title reaches the SVG")
    s = gdash_test.contains_text(s, labelled, ">Period<", "so does an x label")
    s = gdash_test.contains_text(s, labelled, ">Dollars<", "and a y label")

    ' The legend follows the series channel unless the record says otherwise.
    fan = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "line", x: "m", y: "amt", series: "r" } }, ser_rows, "", {}, {})
    s = gdash_test.contains_text(s, fan, "north", "a series channel turns the legend on by itself")
    quiet = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "line", x: "m", y: "amt", series: "r", legend: false } }, ser_rows, "", {}, {})
    s = gdash_test.ok(s, not contains(quiet, "north"), "and the record can turn it off")
    s = gdash_test.ok(s, not contains(plain, ">amt<"), "one line needs no legend to say which line it is")
    named = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "line", x: "m", y: "amt", legend: true } }, num_rows, "", {}, {})
    s = gdash_test.contains_text(s, named, ">amt<", "but the record can ask for one anyway")

    ' A range the data does not reach must still appear on the axis; that is
    ' the whole point of setting one.
    ranged = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "line", x: "m", y: "amt", y_min: 0, y_max: 100 } }, num_rows, "", {}, {})
    s = gdash_test.contains_text(s, ranged, ">100<", "y_max appears as a tick even though no row reaches it")
    s = gdash_test.ok(s, not contains(plain, ">100<"), "and does not appear without it")

    ' Grid lines are <line> elements, so removing the grid removes some.
    gridless = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "line", x: "m", y: "amt", grid: false } }, num_rows, "", {}, {})
    s = gdash_test.ok(s, (count(split(gridless, "<line")) - 1) < (count(split(plain, "<line")) - 1), "grid: false draws fewer lines")

    ' Stacking changes where the bars are, not how many.
    stacked = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "bar", x: "m", y: "amt", series: "r", stacked: true } }, ser_rows, "", {}, {})
    grouped = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "bar", x: "m", y: "amt", series: "r" } }, ser_rows, "", {}, {})
    s = gdash_test.ok(s, stacked != grouped, "stacked renders differently from grouped")
    s = gdash_test.eq(s, count(split(stacked, "<rect")) - 1, count(split(grouped, "<rect")) - 1, "with the same number of bars, in different places")

    ' --- the marks GDASH-7 added (§2.3) ----------------------------------
    '
    ' Asserted on the ELEMENT each mark exists to draw, not on "<svg": an
    ' empty frame is an svg, which is how a blank line chart survived six
    ' phases (G7-3).
    area_out = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "area", x: "m", y: "amt", series: "r" } }, ser_rows, "", {}, {})
    s = gdash_test.ok(s, not contains(area_out, "gdash-error"), "an area renders -- " + mid(area_out, 0, 110))
    s = gdash_test.ok(s, count(split(area_out, "<path")) - 1 >= 2, "with a filled band per series")

    scat = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "scatter", x: "m", y: "amt", series: "r" } }, ser_rows, "", {}, {})
    s = gdash_test.ok(s, not contains(scat, "gdash-error"), "a scatter renders")
    s = gdash_test.eq(s, count(split(scat, "<circle")) - 1, 4, "with a point per row, not a line")
    s = gdash_test.eq(s, count(split(scat, "<path")) - 1, 0, "and no path joining them")

    ' area and scatter share line's axis, so they inherit its ORDINAL x --
    ' they used to inherit its refusal, and that refusal is gone.
    for each mk in ["area", "scatter"]
        cat_rows = [ { m: "Jan", amt: 1.0 }, { m: "Feb", amt: 2.0 } ]
        out = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: mk, x: "m", y: "amt" } }, cat_rows, "", {}, {})
        s = gdash_test.ok(s, not contains(out, "gdash-error"), "mark '" + mk + "' takes a text x like line does")
        s = gdash_test.contains_text(s, out, ">Jan<", "labelling the category on the axis")
    next

    pie_rows = [ { r: "north", amt: 10.0 }, { r: "south", amt: 5.0 }, { r: "east", amt: 22.0 } ]
    pie_out = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "pie", label: "r", value: "amt", title: "Share" } }, pie_rows, "", {}, {})
    s = gdash_test.ok(s, not contains(pie_out, "gdash-error"), "a pie renders -- " + mid(pie_out, 0, 110))
    s = gdash_test.eq(s, count(split(pie_out, "<path")) - 1, 3, "with a slice per label")
    s = gdash_test.contains_text(s, pie_out, ">Share<", "and takes a title")
    s = gdash_test.contains_text(s, pie_out, "north", "labelling its slices without a legend")

    ' A pie names its channels differently, so a wrong one is caught by name.
    pie_bad = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "pie", label: "nope", value: "amt" } }, pie_rows, "", {}, {})
    s = gdash_test.contains_text(s, pie_bad, "channel 'label' names column 'nope'", "a pie's label channel is checked against the query")

    ' --- one value per slot, or say so (GDASH-10) -------------------------
    '
    ' _pivot slots by x and the last row wins, which is an AGGREGATION -- and
    ' design §2 puts aggregation in the SQL. Silently keeping a row at random
    ' is the worst version of it, so the marks that need one value per slot
    ' refuse and name the value.
    dup = [ { m: "Jan", v: 10.0 }, { m: "Jan", v: 20.0 }, { m: "Feb", v: 15.0 } ]
    for each mk in ["bar", "line", "area"]
        out = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: mk, x: "m", y: "v" } }, dup, "", {}, {})
        s = gdash_test.contains_text(s, out, "appears more than once", "mark '" + mk + "' refuses a repeated x rather than dropping a row")
        s = gdash_test.contains_text(s, out, "group by", "and says where the aggregation belongs")
    next

    ' Two SERIES at one x is not a repeat -- that is what a series channel is
    ' for, and refusing it would break every grouped bar.
    pair = [ { m: "Jan", r: "n", v: 10.0 }, { m: "Jan", r: "s", v: 20.0 }, { m: "Feb", r: "n", v: 15.0 } ]
    grouped = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "bar", x: "m", y: "v", series: "r" } }, pair, "", {}, {})
    s = gdash_test.ok(s, not contains(grouped, "gdash-error"), "two series at one x is not a repeat -- " + mid(grouped, 0, 110))

    ' A SCATTER IS ONE POINT PER ROW, so it does not go through the pivot at
    ' all. Four readings with two at the same x drew three circles before
    ' GDASH-10 -- silent data loss in the one mark whose job is every point.
    four = [ { t: 1.0, v: 10.0 }, { t: 2.0, v: 20.0 }, { t: 2.0, v: 35.0 }, { t: 3.0, v: 15.0 } ]
    pts = gdash_render.render_visual("v", { dataset: "d", sql: "x", encoding: { mark: "scatter", x: "t", y: "v" } }, four, "", {}, {})
    s = gdash_test.eq(s, count(split(pts, "<circle")) - 1, 4, "a scatter draws every row, including two at the same x")
    s = gdash_test.ok(s, not contains(pts, "appears more than once"), "and never refuses a repeat, because it loses nothing")

    exit(gdash_test.report(s))
end program
