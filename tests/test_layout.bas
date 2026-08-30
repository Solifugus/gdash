program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_record from "../src/gdash_record.bas"

    s = gdash_test.suite("layout")


    ' --- space values ---
    s = gdash_test.ok(s, gdash_record.legal_space("between"), "between is legal")
    s = gdash_test.ok(s, gdash_record.legal_space("around"), "around is legal")
    s = gdash_test.ok(s, gdash_record.legal_space("evenly"), "evenly is legal")
    s = gdash_test.ok(s, gdash_record.legal_space("start"), "start is legal")
    s = gdash_test.ok(s, gdash_record.legal_space("end"), "end is legal")
    s = gdash_test.ok(s, gdash_record.legal_space("center"), "center is legal")
    s = gdash_test.ok(s, not gdash_record.legal_space("justify"), "an invented space value is not")

    base = { format: 1, name: "b", access: "open", datasets: { d1: { profile: "p", sql: "select 1" } }, params: {}, visuals: { v1: { dataset: "d1", sql: "select a, b from d1", encoding: { mark: "bar", x: "a", y: "b" } } } }

    ' an illegal space value is an ERROR
    r = base
    r["tabs"] = [{ name: "T", layout: { vert: [{ visual: "v1" }], space: "justify" } }]
    e = gdash_record.check(r)
    s = gdash_test.contains_text(s, join(e.errors, "|"), "it must be between", "illegal space refused")

    ' --- the dead-space WARNING (design §2) ---
    ' every child weighted -> space has no leftover room to govern
    r2 = base
    r2["tabs"] = [{ name: "T", layout: { vert: [{ visual: "v1", weight: 1 }], space: "between" } }]
    c2 = gdash_record.check(r2)
    s = gdash_test.eq(s, count(c2.errors), 0, "dead space is not an error")
    s = gdash_test.eq(s, count(c2.warnings), 1, "dead space warns")
    s = gdash_test.contains_text(s, join(c2.warnings, "|"), "every child is weighted", "warning says why")

    ' one child unweighted -> there IS leftover room, so no warning
    r3 = base
    r3["visuals"]["v2"] = { dataset: "d1", sql: "select a, b from d1", encoding: { mark: "bar", x: "a", y: "b" } }
    r3["tabs"] = [{ name: "T", layout: { vert: [{ visual: "v1", weight: 1 }, { visual: "v2" }], space: "between" } }]
    c3 = gdash_record.check(r3)
    s = gdash_test.eq(s, count(c3.warnings), 0, "no warning when a child takes natural size")

    ' no space set at all -> nothing to warn about
    r4 = base
    r4["tabs"] = [{ name: "T", layout: { vert: [{ visual: "v1", weight: 1 }] } }]
    s = gdash_test.eq(s, count(gdash_record.check(r4).warnings), 0, "no space, no warning")

    ' a warning does not refuse the record
    s = gdash_test.eq(s, count(gdash_record.check(r2).errors), 0, "a warned record still loads")

    ' --- weight and gap are checked ---
    r5 = base
    r5["tabs"] = [{ name: "T", layout: { vert: [{ visual: "v1", weight: 0 }] } }]
    s = gdash_test.contains_text(s, join(gdash_record.check(r5).errors, "|"), "'weight' must be a positive number", "zero weight refused")
    r6 = base
    r6["tabs"] = [{ name: "T", layout: { vert: [{ visual: "v1" }], gap: -4 } }]
    s = gdash_test.contains_text(s, join(gdash_record.check(r6).errors, "|"), "'gap' must be a non-negative number", "negative gap refused")

    ' --- tabs need names ---
    r7 = base
    r7["tabs"] = [{ layout: { vert: [{ visual: "v1" }] } }]
    s = gdash_test.contains_text(s, join(gdash_record.check(r7).errors, "|"), "has no 'name'", "an unnamed tab is refused")

    ' --- the reference record carries several tabs and validates clean ---
    ref = gdash_record.load_file("dashboards/sales/draft.json")
    s = gdash_test.eq(s, string(ref.errors), string([]), "reference record has no errors")
    s = gdash_test.eq(s, string(ref.warnings), string([]), "reference record has no warnings")
    s = gdash_test.eq(s, count(ref.record["tabs"]), 3, "reference record has three tabs")

    exit(gdash_test.report(s))
end program
