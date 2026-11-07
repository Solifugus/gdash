' The controls beyond a select (GDASH-19): the date range's closed vocabulary,
' resolved against an INJECTED clock so every expression is pinned exactly with
' no wall time in it, and the multi-select's |a|b| lists.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_controls from "../src/gdash_controls.bas"
    load gdash_record from "../src/gdash_record.bas"

    s = gdash_test.suite("controls")

    ' --- every expression, at a clock chosen for its edges ---
    ' 2026-05-15 is mid-quarter, mid-year, and in a month after a 30-day one.
    t {date}= "2026-05-15"
    want = { today: "2026-05-15..2026-05-15", last_7d: "2026-05-09..2026-05-15", last_30d: "2026-04-16..2026-05-15",
             last_90d: "2026-02-15..2026-05-15", mtd: "2026-05-01..2026-05-15", qtd: "2026-04-01..2026-05-15",
             ytd: "2026-01-01..2026-05-15", last_month: "2026-04-01..2026-04-30", last_quarter: "2026-01-01..2026-03-31",
             last_year: "2025-01-01..2025-12-31" }
    for each ex in keys(want)
        r = gdash_controls.range(ex, t)
        s = gdash_test.eq(s, string(r.from) + ".." + string(r.to), want[ex], ex + " at 2026-05-15")
    next
    ' The edges that go wrong: the first of a year, and a leap February.
    jan {date}= "2026-01-01"
    s = gdash_test.eq(s, string(gdash_controls.range("last_month", jan).from) + ".." + string(gdash_controls.range("last_month", jan).to), "2025-12-01..2025-12-31", "last_month on 1 January is last December")
    s = gdash_test.eq(s, string(gdash_controls.range("last_quarter", jan).from), "2025-10-01", "and last_quarter is last year's fourth")
    mar {date}= "2028-03-10"
    s = gdash_test.eq(s, string(gdash_controls.range("last_month", mar).to), "2028-02-29", "a leap February ends on the 29th")
    s = gdash_test.eq(s, type(gdash_controls.range("mtd", t).from), "datetime", "the bounds are date values, which bind as dates")
    bad = gdash_controls.range("last_fortnight", t)
    s = gdash_test.ok(s, not bad.ok, "an expression outside the vocabulary is refused")
    s = gdash_test.contains_text(s, bad.message, "the ranges are today, last_7d", "naming the vocabulary")

    ' --- the BOOKMARK property: an expression, resolved per render ---
    ' The page and the URL keep `last_30d`; the dates it means move with the
    ' clock. The same supplied values at two clocks give two ranges.
    rec = { controls: { when: { kind: "daterange", param: "period", from: "since", to: "until", dataset: "d", column: "day" } } }
    june {date}= "2026-06-20"
    a = gdash_controls.apply_ranges(rec, { period: "last_30d", since: unknown, until: unknown }, t)
    b = gdash_controls.apply_ranges(rec, { period: "last_30d", since: unknown, until: unknown }, june)
    s = gdash_test.eq(s, a.period, "last_30d", "the expression itself is kept, for the page and the URL")
    s = gdash_test.eq(s, string(a.since), "2026-04-16", "and resolves at one clock")
    s = gdash_test.eq(s, string(b.since), "2026-05-22", "and differently at another -- March's bookmark does not mean March in June")
    c1 {date}= "2026-01-02"
    c2 {date}= "2026-01-09"
    cu = gdash_controls.apply_ranges(rec, { period: "custom", since: c1, until: c2 }, t)
    s = gdash_test.eq(s, string(cu.since) + ".." + string(cu.until), "2026-01-02..2026-01-09", "custom keeps its own absolute dates")

    pe = join(gdash_controls.control_param_errors(rec, { period: "last_fortnight" }), " | ")
    s = gdash_test.contains_text(s, pe, "param 'period'", "a supplied expression outside the vocabulary is refused by name")
    s = gdash_test.eq(s, count(gdash_controls.control_param_errors(rec, { period: "ytd" })), 0, "a supplied one inside it is not")

    ' --- multi-select lists ---
    s = gdash_test.ok(s, gdash_controls.list_shaped("|west|"), "one value")
    s = gdash_test.ok(s, gdash_controls.list_shaped("|west|east|"), "several")
    s = gdash_test.ok(s, gdash_controls.list_shaped("||"), "and none")
    s = gdash_test.ok(s, not gdash_controls.list_shaped("west|east"), "delimiters are required at both ends")
    s = gdash_test.ok(s, not gdash_controls.list_shaped("|west||east|"), "and no member may be empty")
    s = gdash_test.eq(s, string(gdash_controls.members("|west|east|")), string(["west", "east"]), "members come back in order")
    lo = gdash_controls.list_of(["west", "a|b", "east"])
    s = gdash_test.eq(s, lo.list, "|west|east|", "a value containing the delimiter cannot escape its own list")
    s = gdash_test.eq(s, lo.dropped, 1, "and the caller is told it was left out")
    mrec = { controls: { regions: { kind: "multiselect", param: "regions" } } }
    s = gdash_test.contains_text(s, join(gdash_controls.control_param_errors(mrec, { regions: "west,east" }), "|"), "must be a list written |a|b|", "a malformed list is refused")

    ' --- load-time validation of the two kinds ---
    good = { format: 1, name: "d", access: "open",
             datasets: { orders: { profile: "p", sql: "select 1", columns: { day: { type: "date" } } } },
             params: { period: { default: "last_30d" }, since: { default: "2026-01-01", type: "date" }, until: { default: "2026-12-31", type: "date" },
                       regions: { default: "||" } },
             controls: { when: { kind: "daterange", param: "period", from: "since", to: "until", dataset: "orders", column: "day" },
                         pick: { kind: "multiselect", param: "regions", dataset: "orders", sql: "select distinct region from orders" } },
             visuals: {}, tabs: [{ name: "T", layout: { vert: [{ control: "when" }, { control: "pick" }] } }] }
    s = gdash_test.eq(s, string(gdash_record.validate(good)), string([]), "a date range and a multi-select validate")

    broken = good
    broken["params"] = { period: { default: "last_fortnight" }, since: { default: "2026-01-01" }, regions: { default: "west" } }
    broken["controls"]["when"]["column"] = "month"
    bv = join(gdash_record.validate(broken), " | ")
    s = gdash_test.contains_text(s, bv, "whose default 'last_fortnight' is not a range", "an unknown default expression is refused at load")
    s = gdash_test.contains_text(s, bv, "'from' param 'since', which must be declared with type date", "a range's params must be dates")
    s = gdash_test.contains_text(s, bv, "'to' param 'until', which is not a declared param", "and declared")
    s = gdash_test.contains_text(s, bv, "ranges over 'orders.month', which is not declared", "and its column must be declared a date")
    s = gdash_test.contains_text(s, bv, "whose default 'west' is not a list", "a multi-select's default must be a list")
    odd = good
    odd["controls"] = { x: { kind: "slider", param: "period" } }
    s = gdash_test.contains_text(s, join(gdash_record.validate(odd), "|"), "has kind 'slider'; this build implements select, multiselect, daterange", "an unknown kind is refused by name")

    exit(gdash_test.report(s))
end program
