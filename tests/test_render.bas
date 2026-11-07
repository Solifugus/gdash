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
    live = gdash_paths.stage_db(p, "sales", "draft")

    ' Currency formatting itself is pinned in test_format; what matters
    ' here is that a visual renders THROUGH it.
    s = gdash_test.eq(s, gdash_render.money_scale(live), 2, "scale read from the dataset")

    ' --- the value mark ---
    gt = rec["visuals"]["grand_total"]
    res = gdash_store.select_rows(live, gt["sql"], {})
    s = gdash_test.ok(s, res.ok, "value query runs")
    frag = gdash_render.render_visual("grand_total", gt, res.rows, live, {})
    s = gdash_test.contains_text(s, frag, "gdash-value", "value mark renders a value fragment")
    ' 1250.75+900.25+1100.00+640.10+725.90+310.05 = 4927.05
    s = gdash_test.contains_text(s, frag, "$4,927.05", "value mark shows the exact total")

    ' --- the bar mark, a DIFFERENT render path off the same record shape ---
    bm = rec["visuals"]["by_month"]
    bres = gdash_store.select_rows(live, bm["sql"], { region: "west" })
    s = gdash_test.ok(s, bres.ok, "bar query runs")
    bfrag = gdash_render.render_visual("by_month", bm, bres.rows, live, {})
    s = gdash_test.contains_text(s, bfrag, "<svg", "bar mark renders SVG")
    s = gdash_test.ok(s, not contains(bfrag, "gdash-error"), "bar mark rendered without error")
    ' Two marks, two fragment kinds, from one record shape: the dispatch is real.
    s = gdash_test.ok(s, not contains(frag, "<svg"), "value and bar produce different fragment kinds")

    ' The param actually filtered: west has 3 months, and a different region
    ' gives a different chart.
    s = gdash_test.eq(s, count(bres.rows), 3, "west has three months")
    nres = gdash_store.select_rows(live, bm["sql"], { region: "north" })
    s = gdash_test.eq(s, count(nres.rows), 1, "north has one month")
    nfrag = gdash_render.render_visual("by_month", bm, nres.rows, live, {})
    s = gdash_test.ok(s, nfrag != bfrag, "a different param value renders a different chart")

    ' --- channel validation at query time, the F4 fallback ---
    broken = { dataset: "orders", sql: "select month as month, sum(amount) as total from orders group by month", encoding: { mark: "bar", x: "month", y: "ghost", format: "currency" } }
    bres2 = gdash_store.select_rows(live, broken["sql"], {})
    bad = gdash_render.render_visual("broken", broken, bres2.rows, live, {})
    s = gdash_test.contains_text(s, bad, "gdash-error", "a channel naming no column is refused")
    s = gdash_test.contains_text(s, bad, "which the query does not return", "and says what is wrong")

    ' --- empty result is not an error ---
    eres = gdash_store.select_rows(live, bm["sql"], { region: "nowhere" })
    s = gdash_test.contains_text(s, gdash_render.render_visual("by_month", bm, eres.rows, live, {}), "No data", "empty result renders as empty, not broken")

    ' --- markup is escaped, not interpolated ---
    ctl = rec["controls"]["region_picker"]
    html = gdash_render.render_control("region_picker", ctl, ["west", "<script>x</script>"], "west")
    s = gdash_test.contains_text(s, html, "&lt;script&gt;", "option text is escaped")
    s = gdash_test.ok(s, not contains(html, "<script>"), "no raw script tag survives")
    s = gdash_test.contains_text(s, html, "selected", "current value is selected")

    ' --- money that is not dollars (GDASH-13) -------------------------------
    '
    ' Every money assertion above this line is USD at scale 2, in a dashboard
    ' whose datasets all agree on that scale. That is why four defects lived
    ' here for thirteen phases. A multi-currency position report -- USD at
    ' scale 2 and JPY at scale 0, in ONE dataset, which is what a position
    ' report is -- is the shape that finds them.
    posp = root + "/positions.gsql"
    pcols = ["account", "usd_value", "jpy_value"]
    prows = [["ACC-1", "1250750.25", "430000"], ["ACC-2", "-90425.10", "12"]]
    pplan = gdash_store.plan_columns(pcols, prows, { usd_value: { type: "money", scale: 2 },
                                                    jpy_value: { type: "money", scale: 0, currency: "JPY" } })
    pm = gdash_store.materialize(posp, "positions", pplan, prows)
    pms = gdash_store.swap(posp, "positions")
    s = gdash_test.ok(s, pm.ok and pms.ok, "a two-currency dataset materializes")
    ' Dollars added to yen is not an amount: G-SQL refuses the arithmetic,
    ' where integer minor units would have added them without a word.
    mixedsum = gdash_store.select_rows(posp, "select usd_value + jpy_value as total from positions", {})
    s = gdash_test.ok(s, not mixedsum.ok, "adding dollars to yen is refused by the engine")

    scales = gdash_render.money_scales(posp)
    s = gdash_test.eq(s, scales["usd_value"], 2, "the dollar column keeps its own scale")
    s = gdash_test.eq(s, scales["jpy_value"], 0, "and the yen column keeps its own, which is zero")
    s = gdash_test.eq(s, gdash_render.money_scale(posp), -2, "there is no single scale for this dataset, and saying so is the point")

    ' scale_of is the function the renderer actually consults.
    s = gdash_test.eq(s, gdash_render.scale_of(scales, "jpy_value"), 0, "a money column resolves to its own scale")
    s = gdash_test.eq(s, gdash_render.scale_of(scales, "unknown_alias"), -2, "an aliased column over disagreeing scales does not resolve")
    s = gdash_test.eq(s, gdash_render.scale_of({}, "anything"), -1, "and no money at all is a different answer from ambiguity")
    s = gdash_test.eq(s, gdash_render.scale_of({ amount: 2, other: 2 }, "total"), 2, "where every money column agrees, an alias still resolves")

    postab = { dataset: "positions",
               sql: "select account, usd_value, jpy_value from positions order by account",
               encoding: { mark: "table", title: "Positions",
                           formats: { usd_value: { name: "currency", currency: "USD" },
                                      jpy_value: { name: "currency", currency: "JPY" } } } }
    pres = gdash_store.select_rows(posp, postab["sql"], {})
    s = gdash_test.ok(s, pres.ok, "the positions query runs")
    ptab = gdash_render.render_visual("positions_table", postab, pres.rows, posp, {})

    ' THE DEFECT, AS IT APPEARED: every yen figure was rendered at scale 2 --
    ' a hundred times small -- in a table that looked entirely normal. A real
    ' balance of 12 yen showed as 0.
    s = gdash_test.contains_text(s, ptab, "$1,250,750.25", "the dollar column is right")
    s = gdash_test.contains_text(s, ptab, "-$90,425.10", "including a negative one")
    s = gdash_test.contains_text(s, ptab, "¥430,000", "and the yen column is right at ITS scale, not the dollar one")
    s = gdash_test.contains_text(s, ptab, "¥12", "a balance of twelve yen is twelve yen")
    s = gdash_test.ok(s, not contains(ptab, "¥4,300"), "and not four thousand three hundred, which is what scale 2 made of it")

    ' ONE CODEPOINT. `chr(194) + chr(165)` is the two UTF-8 BYTES of the yen
    ' sign handed to a function that takes codepoints, and it is what shipped.
    s = gdash_test.ok(s, not contains(ptab, chr(194) + chr(165)), "the yen sign is not double-encoded")

    ' A sibling's scale must not decide a visual that never touches it. This
    ' refused outright before: `money_scale` read the money columns of the
    ' primary AND every attachment, so one yen column anywhere in a dashboard
    ' disabled currency formatting everywhere in it.
    ledgerp = root + "/ledger13.gsql"
    lrows = [["2026-07", "1250.75"], ["2026-08", "-430.00"]]
    lplan = gdash_store.plan_columns(["month", "amount"], lrows, { amount: { type: "money", scale: 2 } })
    lm = gdash_store.materialize(ledgerp, "ledger", lplan, lrows)
    lms = gdash_store.swap(ledgerp, "ledger")
    s = gdash_test.ok(s, lm.ok and lms.ok, "a single-currency dataset materializes beside it")

    monthly = { dataset: "ledger",
                sql: "select month, sum(amount) as amount from ledger group by month order by month",
                encoding: { mark: "bar", x: "month", y: "amount", format: "currency", currency: "USD" } }
    mres = gdash_store.select_rows(ledgerp, monthly["sql"], {})
    s = gdash_test.ok(s, mres.ok, "the monthly query runs")
    mfrag = gdash_render.render_visual("monthly", monthly, mres.rows, ledgerp, {})
    s = gdash_test.ok(s, not contains(mfrag, "gdash-error"), "a visual over one dataset is not disabled by another's scale")
    s = gdash_test.contains_text(s, mfrag, "<svg", "it draws")

    ' And what is still genuinely ambiguous REFUSES, naming the column, rather
    ' than formatting at a guess. This is the case that used to be silent.
    ' (An alias over ONE currency: `usd_value + jpy_value` is now refused by
    ' G-SQL itself, as dollars added to yen.)
    aliased = { dataset: "positions",
                sql: "select account, usd_value * 1 as total from positions",
                encoding: { mark: "bar", x: "account", y: "total", format: "currency", currency: "USD" } }
    ares = gdash_store.select_rows(posp, aliased["sql"], {})
    afrag = gdash_render.render_visual("aliased", aliased, ares.rows, posp, {})
    s = gdash_test.contains_text(s, afrag, "gdash-error", "an alias with no resolvable scale is refused")
    s = gdash_test.contains_text(s, afrag, "total", "and the refusal names the column")
    s = gdash_test.contains_text(s, afrag, "Alias it", "and says what to do about it")

    ' A TABLE column that is formatted as currency and whose scale does not
    ' resolve must refuse too. Without this the table's refusal branch is never
    ' taken by any fixture here, and "fall back to 2" -- the defect exactly as
    ' it shipped -- passes every other assertion in this file. Found by
    ' mutation, which is the only thing that could have found it.
    aliastab = { dataset: "positions",
                 sql: "select account, usd_value * 1 as total from positions",
                 encoding: { mark: "table",
                             formats: { total: { name: "currency", currency: "USD" } } } }
    tres = gdash_store.select_rows(posp, aliastab["sql"], {})
    tfrag = gdash_render.render_visual("aliastab", aliastab, tres.rows, posp, {})
    s = gdash_test.contains_text(s, tfrag, "gdash-error", "a table cell with no resolvable scale is refused, not formatted at 2")
    s = gdash_test.contains_text(s, tfrag, "total", "naming the column")

    ' A percent or number column in the same table must NOT be refused because
    ' money elsewhere is ambiguous -- it needs no money scale at all.
    mixedfmt = { dataset: "positions",
                 sql: "select account, usd_value, jpy_value from positions",
                 encoding: { mark: "table",
                             formats: { usd_value: { name: "currency", currency: "USD" },
                                        jpy_value: { name: "number", decimals: 0 } } } }
    xres = gdash_store.select_rows(posp, mixedfmt["sql"], {})
    xfrag = gdash_render.render_visual("mixedfmt", mixedfmt, xres.rows, posp, {})
    s = gdash_test.ok(s, not contains(xfrag, "gdash-error"), "a non-money format is not refused over a money ambiguity")

    exit(gdash_test.report(s))
end program
