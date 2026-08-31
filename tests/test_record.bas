program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_record from "../src/gdash_record.bas"

    s = gdash_test.suite("record")
    root = args[0]

    ' --- the reference record validates clean ---
    ref = gdash_record.load_file("dashboards/sales/draft.json")
    s = gdash_test.eq(s, string(ref.errors), string([]), "reference record has no validation errors")
    s = gdash_test.ok(s, ref.ok, "reference record loads")
    rec = ref.record

    ' --- the dependency graph is DERIVED from :name bindings (design §2) ---
    binding = gdash_record.visuals_binding(rec, "region")
    s = gdash_test.eq(s, string(binding), string(["by_month"]), "only the visual binding :region re-runs")
    s = gdash_test.ok(s, not contains(binding, "grand_total"), "a visual that does not bind the param stays put")
    s = gdash_test.eq(s, count(gdash_record.visuals_binding(rec, "nosuch")), 0, "unknown param moves nothing")

    ' --- params resolve from defaults, overlaid by supplied values ---
    d = gdash_record.resolve_params(rec, {}, unknown)
    s = gdash_test.eq(s, d["region"], "west", "default param value")
    o = gdash_record.resolve_params(rec, { region: "east" }, unknown)
    s = gdash_test.eq(s, o["region"], "east", "supplied value overrides default")
    ' An undeclared param is ignored rather than reaching SQL.
    x = gdash_record.resolve_params(rec, { region: "east", injected: "1=1" }, unknown)
    s = gdash_test.ok(s, is_unknown(x["injected"]), "undeclared param is dropped")

    ' --- user_* is injected, never accepted (design §2) ---
    ident = { name: "ada", email: "ada@example.invalid", groups: ["analysts", "finance"] }
    u = gdash_record.resolve_params(rec, {}, ident)
    s = gdash_test.eq(s, u["user_name"], "ada", "user_name is injected from the identity")
    s = gdash_test.eq(s, u["user_email"], "ada@example.invalid", "so is user_email")
    s = gdash_test.eq(s, u["user_groups"], "|analysts|finance|", "groups arrive delimited on both ends")

    ' A group merely ENDING in another group's name must not match a `like`.
    s = gdash_test.ok(s, contains(u["user_groups"], "|finance|"), "a whole group matches")
    s = gdash_test.ok(s, not contains(gdash_record.resolve_params(rec, {}, { name: "x", email: "x", groups: ["cofinance"] })["user_groups"], "|finance|"), "and a group that merely ends in one does not")

    ' The client cannot set them. This is the whole of design §5's claim that
    ' a user-filtered dashboard over a shared dataset is genuinely secure.
    spoofed = gdash_record.resolve_params(rec, { user_email: "someone.else@example.invalid", user_groups: "|admins|" }, ident)
    s = gdash_test.eq(s, spoofed["user_email"], "ada@example.invalid", "a client-supplied user_email is ignored")
    s = gdash_test.eq(s, spoofed["user_groups"], "|analysts|finance|", "and so are client-supplied groups")

    ' An anonymous viewer gets empty strings, not missing bindings: a query
    ' binding :user_email must still run, and match nothing.
    anon = gdash_record.resolve_params(rec, {}, unknown)
    s = gdash_test.eq(s, anon["user_email"], "", "an anonymous viewer has an empty user_email")
    s = gdash_test.eq(s, anon["user_groups"], "||", "and no groups")

    ' --- refusals. GDASH-1 freezes these messages as goldens; this phase only
    '     pins that the right condition is caught. ---

    ' Params may appear ONLY in visual queries (design §2).
    bad = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select * from t where r = :region" } }, params: { region: { default: "w" } }, visuals: {}, tabs: [{ layout: { vert: [] } }] }
    e = gdash_record.validate(bad)
    s = gdash_test.ok(s, count(e) > 0, "param in a dataset query is refused")
    s = gdash_test.contains_text(s, join(e, "|"), "only in visual queries", "refusal names the rule")

    ' Every binding resolves, before any database is touched.
    bad2 = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select * from t" } }, params: {}, visuals: { v1: { dataset: "d1", sql: "select a, b from d1 where x = :ghost", encoding: { mark: "bar", x: "a", y: "b" } } }, tabs: [{ layout: { visual: "v1" } }] }
    e2 = gdash_record.validate(bad2)
    s = gdash_test.contains_text(s, join(e2, "|"), "not a declared param", "unresolved binding is refused")

    ' Dataset names become table names.
    bad3 = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select 1" } }, params: {}, visuals: {}, tabs: [{ layout: { vert: [] } }] }
    bad3.datasets["2bad"] = { profile: "p", sql: "select 1" }
    e3 = gdash_record.validate(bad3)
    s = gdash_test.contains_text(s, join(e3, "|"), "not a legal SQL identifier", "illegal dataset name is refused")

    ' Every layout leaf names a defined visual or control.
    bad4 = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select 1" } }, params: {}, visuals: {}, tabs: [{ layout: { vert: [{ visual: "ghost" }] } }] }
    e4 = gdash_record.validate(bad4)
    s = gdash_test.contains_text(s, join(e4, "|"), "undefined visual", "dangling layout leaf is refused")

    ' Nested containers are walked, not just the top level.
    bad5 = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select 1" } }, params: {}, visuals: {}, tabs: [{ layout: { vert: [{ horiz: [{ control: "ghost" }] }] } }] }
    e5 = gdash_record.validate(bad5)
    s = gdash_test.contains_text(s, join(e5, "|"), "undefined control", "nested dangling leaf is refused")

    ' An unknown mark is refused rather than rendered as something else.
    bad6 = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select 1" } }, params: {}, visuals: { v1: { dataset: "d1", sql: "select a from d1", encoding: { mark: "sankey" } } }, tabs: [{ layout: { visual: "v1" } }] }
    e6 = gdash_record.validate(bad6)
    s = gdash_test.contains_text(s, join(e6, "|"), "sankey", "unknown mark is refused")

    ' A money column without a scale cannot materialize (design §4).
    bad7 = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select 1", columns: { amt: { type: "money" } } } }, params: {}, visuals: {}, tabs: [{ layout: { vert: [] } }] }
    e7 = gdash_record.validate(bad7)
    s = gdash_test.contains_text(s, join(e7, "|"), "no 'scale'", "money column without scale is refused")

    ' Format version is checked.
    bad8 = { format: 99, name: "b", datasets: {}, params: {}, visuals: {}, tabs: [{ layout: { vert: [] } }] }
    s = gdash_test.contains_text(s, join(gdash_record.validate(bad8), "|"), "unsupported record format", "unknown format version refused")

    ' A refresh policy that does not exist is refused, not ignored.
    bad9 = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select 1", refresh: "hourly" } }, params: {}, visuals: {}, tabs: [{ layout: { vert: [] } }] }
    s = gdash_test.contains_text(s, join(gdash_record.validate(bad9), "|"), "the policies are", "an invented refresh policy refused")

    ' An interval without a period is a schedule that cannot run.
    bad9b = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select 1", refresh: "interval" } }, params: {}, visuals: {}, tabs: [{ layout: { vert: [] } }] }
    s = gdash_test.contains_text(s, join(gdash_record.validate(bad9b), "|"), "no 'every'", "interval without a period refused")

    ' A period beside a policy that will never use it reads as a schedule
    ' that silently does nothing, which is worse than no schedule at all.
    bad9c = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select 1", refresh: "manual", every: 300 } }, params: {}, visuals: {}, tabs: [{ layout: { vert: [] } }] }
    s = gdash_test.contains_text(s, join(gdash_record.validate(bad9c), "|"), "belongs only to 'interval'", "a stray 'every' is refused")

    ' A valid interval dataset passes.
    good9 = { format: 1, name: "b", access: "open", datasets: { d1: { profile: "p", sql: "select 1", refresh: "interval", every: 300 } }, params: {}, visuals: {}, tabs: [{ name: "t", layout: { vert: [] } }] }
    s = gdash_test.eq(s, count(gdash_record.validate(good9)), 0, "a well-formed interval dataset validates")

    ' Eleven datasets is the ceiling; twelve is refused at load rather than
    ' at render (finding G2-4).
    many = {}
    mi = 0
    while mi < 12
        many["d" + string(mi)] = { profile: "p", sql: "select 1" }
        mi += 1
    end while
    toomany = { format: 1, name: "b", datasets: many, params: {}, visuals: {}, tabs: [{ name: "t", layout: { vert: [] } }] }
    s = gdash_test.contains_text(s, join(gdash_record.validate(toomany), "|"), "SQLite attaches at most", "a twelfth dataset is refused at load")

    ' --- load failures are values, not raises ---
    miss = gdash_record.load_file(root + "/nope.json")
    s = gdash_test.ok(s, not miss.ok, "missing record file fails")
    s = gdash_test.contains_text(s, join(miss.errors, "|"), "not found", "missing file says so")

    junk = root + "/junk.json"
    jf {file} = junk
    write(jf, "{ this is not json")
    bad_parse = gdash_record.load_file(junk)
    s = gdash_test.ok(s, not bad_parse.ok, "malformed record fails")
    s = gdash_test.contains_text(s, join(bad_parse.errors, "|"), "not valid JSON", "malformed file says so")

    exit(gdash_test.report(s))
end program
