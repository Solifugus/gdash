' The validation catalog, pinned byte-for-byte.
'
' GDASH-0 asserted only that the right CONDITION was caught, so wording could
' change without rewriting assertions. GDASH-1 pays that debt: every refusal
' and every warning this build can emit is driven here and compared against
' tests/goldens/validation.golden.
'
' Regenerate deliberately with GDASH_UPDATE_GOLDENS=1. A diff in this file is
' a change to gdash's public error contract and should be read as one.

' A minimal valid skeleton each case perturbs in exactly one way, so a case
' produces only the message it is about.
function skeleton()
    return { format: 1, name: "b", access: "open", datasets: { d1: { profile: "p", sql: "select 1" } }, params: { region: { default: "w" } }, visuals: { v1: { dataset: "d1", sql: "select a, b from d1", encoding: { mark: "bar", x: "a", y: "b" } } }, controls: {}, tabs: [{ name: "T", layout: { vert: [{ visual: "v1" }] } }] }
end function

function ds_case(nm, ds)
    r = skeleton()
    r["datasets"] = {}
    r["datasets"][nm] = ds
    r["visuals"] = {}
    r["tabs"] = [{ name: "T", layout: { vert: [] } }]
    return r
end function

function vis_case(v)
    r = skeleton()
    r["visuals"] = { v1: v }
    r["tabs"] = [{ name: "T", layout: { vert: [] } }]
    return r
end function

function ctl_case(c)
    r = skeleton()
    r["controls"] = { c1: c }
    return r
end function

function tab_case(tb)
    r = skeleton()
    r["tabs"] = [tb]
    return r
end function

' One line per case: label, then errors and warnings in emission order.
function emit_case(label, rec)
    load gdash_record from "../src/gdash_record.bas"
    got = gdash_record.check(rec)
    parts = []
    i = 0
    while i < count(got.errors)
        parts = concat(parts, ["ERROR " + got.errors[i]])
        i += 1
    end while
    i = 0
    while i < count(got.warnings)
        parts = concat(parts, ["WARN  " + got.warnings[i]])
        i += 1
    end while
    if count(parts) = 0 then
        return label + chr(10) + "  (no diagnostics)"
    end if
    return label + chr(10) + "  " + join(parts, chr(10) + "  ")
end function

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_record from "../src/gdash_record.bas"

    s = gdash_test.suite("goldens")
    root = args[0]

    lines = []


    ' --- record level ---
    lines = concat(lines, [emit_case("format missing", { name: "b", datasets: {}, visuals: {}, tabs: [] })])
    lines = concat(lines, [emit_case("format unsupported", { format: 99, name: "b", datasets: {}, visuals: {}, tabs: [] })])
    lines = concat(lines, [emit_case("name missing", { format: 1, datasets: {}, visuals: {}, tabs: [] })])
    lines = concat(lines, [emit_case("access unsupported", { format: 1, name: "b", access: "public", datasets: {}, visuals: {}, tabs: [] })])
    lines = concat(lines, [emit_case("datasets missing", { format: 1, name: "b", visuals: {}, tabs: [] })])
    lines = concat(lines, [emit_case("visuals missing", { format: 1, name: "b", datasets: {}, tabs: [] })])
    lines = concat(lines, [emit_case("tabs missing", { format: 1, name: "b", datasets: {}, visuals: {} })])
    lines = concat(lines, [emit_case("tabs empty", { format: 1, name: "b", datasets: {}, visuals: {}, tabs: [] })])

    ' --- datasets ---
    lines = concat(lines, [emit_case("dataset illegal name", ds_case("2bad", { profile: "p", sql: "select 1" }))])
    lines = concat(lines, [emit_case("dataset sql missing", ds_case("d1", { profile: "p" }))])
    lines = concat(lines, [emit_case("dataset profile missing", ds_case("d1", { sql: "select 1" }))])
    lines = concat(lines, [emit_case("dataset binds a param", ds_case("d1", { profile: "p", sql: "select * from t where r = :region" }))])
    lines = concat(lines, [emit_case("dataset refresh policy", ds_case("d1", { profile: "p", sql: "select 1", refresh: "hourly" }))])
    lines = concat(lines, [emit_case("interval without a period", ds_case("d1", { profile: "p", sql: "select 1", refresh: "interval" }))])
    lines = concat(lines, [emit_case("interval period not a whole number", ds_case("d1", { profile: "p", sql: "select 1", refresh: "interval", every: 0.5 }))])
    lines = concat(lines, [emit_case("period without an interval", ds_case("d1", { profile: "p", sql: "select 1", refresh: "manual", every: 300 }))])
    lines = concat(lines, [emit_case("min_age without on_open", ds_case("d1", { profile: "p", sql: "select 1", refresh: "manual", min_age: 60 }))])
    lines = concat(lines, [emit_case("min_age not a whole number", ds_case("d1", { profile: "p", sql: "select 1", refresh: "on_open", min_age: -1 }))])

    ' Twelve datasets: one more than SQLite will attach beside the one being
    ' queried, refused at load rather than at render.
    crowd = skeleton()
    crowd["datasets"] = {}
    crowd["visuals"] = {}
    crowd["tabs"] = [{ name: "T", layout: { vert: [] } }]
    ci = 0
    while ci < 12
        crowd["datasets"]["d" + string(ci)] = { profile: "p", sql: "select 1" }
        ci += 1
    end while
    lines = concat(lines, [emit_case("too many datasets", crowd)])
    lines = concat(lines, [emit_case("money scale missing", ds_case("d1", { profile: "p", sql: "select 1", columns: { amt: { type: "money" } } }))])
    lines = concat(lines, [emit_case("money scale negative", ds_case("d1", { profile: "p", sql: "select 1", columns: { amt: { type: "money", scale: -1 } } }))])
    lines = concat(lines, [emit_case("money currency unsupported", ds_case("d1", { profile: "p", sql: "select 1", columns: { amt: { type: "money", scale: 2, currency: "XYZ" } } }))])

    ' --- visuals ---
    lines = concat(lines, [emit_case("visual dataset missing", vis_case({ sql: "select a from d1", encoding: { mark: "value", value: "a" } }))])
    lines = concat(lines, [emit_case("visual dataset unknown", vis_case({ dataset: "nope", sql: "select a from d1", encoding: { mark: "value", value: "a" } }))])
    lines = concat(lines, [emit_case("visual sql missing", vis_case({ dataset: "d1", encoding: { mark: "value", value: "a" } }))])
    lines = concat(lines, [emit_case("visual binding unresolved", vis_case({ dataset: "d1", sql: "select a from d1 where x = :ghost", encoding: { mark: "value", value: "a" } }))])
    lines = concat(lines, [emit_case("visual encoding missing", vis_case({ dataset: "d1", sql: "select a from d1" }))])
    lines = concat(lines, [emit_case("visual mark missing", vis_case({ dataset: "d1", sql: "select a from d1", encoding: { value: "a" } }))])
    lines = concat(lines, [emit_case("visual mark unknown", vis_case({ dataset: "d1", sql: "select a from d1", encoding: { mark: "sankey" } }))])
    lines = concat(lines, [emit_case("bar missing channels", vis_case({ dataset: "d1", sql: "select a from d1", encoding: { mark: "bar", x: "a" } }))])
    lines = concat(lines, [emit_case("value missing channel", vis_case({ dataset: "d1", sql: "select a from d1", encoding: { mark: "value" } }))])
    lines = concat(lines, [emit_case("table with channels", vis_case({ dataset: "d1", sql: "select a from d1", encoding: { mark: "table", x: "a" } }))])
    lines = concat(lines, [emit_case("series on wrong mark", vis_case({ dataset: "d1", sql: "select a from d1", encoding: { mark: "value", value: "a", series: "a" } }))])
    lines = concat(lines, [emit_case("format unknown", vis_case({ dataset: "d1", sql: "select a from d1", encoding: { mark: "value", value: "a", format: "sparkline" } }))])
    lines = concat(lines, [emit_case("formats on wrong mark", vis_case({ dataset: "d1", sql: "select a from d1", encoding: { mark: "value", value: "a", formats: { a: "currency" } } }))])
    lines = concat(lines, [emit_case("formats unknown name", vis_case({ dataset: "d1", sql: "select a from d1", encoding: { mark: "table", formats: { a: "sparkline" } } }))])
    lines = concat(lines, [emit_case("visual currency unsupported", vis_case({ dataset: "d1", sql: "select a from d1", encoding: { mark: "value", value: "a", currency: "XYZ" } }))])

    ' --- controls ---
    lines = concat(lines, [emit_case("control kind", ctl_case({ kind: "radio", param: "region" }))])
    lines = concat(lines, [emit_case("control param missing", ctl_case({ kind: "select" }))])
    lines = concat(lines, [emit_case("control param undeclared", ctl_case({ kind: "select", param: "ghost" }))])
    lines = concat(lines, [emit_case("control dataset unknown", ctl_case({ kind: "select", param: "region", dataset: "nope" }))])

    ' --- layout ---
    lines = concat(lines, [emit_case("tab name missing", tab_case({ layout: { vert: [] } }))])
    lines = concat(lines, [emit_case("tab layout missing", tab_case({ name: "T" }))])
    lines = concat(lines, [emit_case("layout leaf unknown visual", tab_case({ name: "T", layout: { vert: [{ visual: "ghost" }] } }))])
    lines = concat(lines, [emit_case("layout leaf unknown control", tab_case({ name: "T", layout: { vert: [{ control: "ghost" }] } }))])
    lines = concat(lines, [emit_case("layout node unrecognised", tab_case({ name: "T", layout: { vert: [{ widget: "x" }] } }))])
    lines = concat(lines, [emit_case("layout container not array", tab_case({ name: "T", layout: { vert: "nope" } }))])
    lines = concat(lines, [emit_case("space illegal", tab_case({ name: "T", layout: { vert: [{ visual: "v1" }], space: "justify" } }))])
    lines = concat(lines, [emit_case("gap negative", tab_case({ name: "T", layout: { vert: [{ visual: "v1" }], gap: -1 } }))])
    lines = concat(lines, [emit_case("weight zero", tab_case({ name: "T", layout: { vert: [{ visual: "v1", weight: 0 }] } }))])

    ' --- warnings ---
    lines = concat(lines, [emit_case("WARNING dead space", tab_case({ name: "T", layout: { vert: [{ visual: "v1", weight: 1 }], space: "between" } }))])

    actual = join(lines, chr(10)) + chr(10)
    gpath = "tests/goldens/validation.golden"

    if default(env("GDASH_UPDATE_GOLDENS"), "0") = "1" then
        gf {file} = gpath
        write(gf, actual)
        print("goldens rewritten: " + gpath)
        exit(0)
    end if

    ef {file} = gpath
    if not exists(ef) then
        print to error "golden file missing: " + gpath
        print to error "regenerate with GDASH_UPDATE_GOLDENS=1"
        exit(1)
    end if
    expected = read(ef)

    if actual = expected then
        s = gdash_test.ok(s, true, "validation catalog matches its golden")
    else
        ' Write the actual next to the scratch root so a diff is possible.
        af {file} = root + "/validation.actual"
        write(af, actual)
        s = gdash_test.ok(s, false, "validation catalog DIFFERS from its golden -- actual written to " + root + "/validation.actual")
        al = split(actual, chr(10))
        el = split(expected, chr(10))
        i = 0
        shown = 0
        while i < count(al) and shown < 6
            got = ""
            want = ""
            if i < count(al) then
                got = al[i]
            end if
            if i < count(el) then
                want = el[i]
            end if
            if got != want then
                print("  line " + string(i + 1) + " expected: " + want)
                print("  line " + string(i + 1) + " actual  : " + got)
                shown += 1
            end if
            i += 1
        end while
    end if

    exit(gdash_test.report(s))
end program
