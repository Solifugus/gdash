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

    ' --- adversarial (GDASH-6 §2.6) --------------------------------------
    '
    ' `check` is the front door for author-supplied JSON: whatever `try_decode`
    ' will parse can arrive here. The bar is REFUSE, NEVER RAISE, AND NEVER
    ' HANG. A validator that crashes on a malformed record is a validator that
    ' cannot report on one, and the CLI's whole job is to say what is wrong.

    ' The record itself, of every wrong shape.
    s = gdash_test.ok(s, count(gdash_record.check({}).errors) > 0, "an empty record is refused, not accepted")
    s = gdash_test.ok(s, count(gdash_record.check({ format: 1 }).errors) > 0, "a record with only a format is refused")

    ' Wrong TYPES in every slot that expects a container. Each of these would
    ' be a crash if the validator indexed before it checked.
    wrong_types = [
        { format: 1, name: "b", datasets: "not an object", visuals: {}, tabs: [{ name: "T", layout: { vert: [] } }] },
        { format: 1, name: "b", datasets: {}, visuals: "not an object", tabs: [{ name: "T", layout: { vert: [] } }] },
        { format: 1, name: "b", datasets: {}, visuals: {}, tabs: "not an array" },
        { format: 1, name: "b", datasets: {}, visuals: {}, tabs: [{ name: "T", layout: "not an object" }] },
        { format: 1, name: "b", datasets: {}, visuals: {}, tabs: [ "not an object" ] },
        { format: 1, name: "b", datasets: {}, visuals: {}, params: "not an object", tabs: [{ name: "T", layout: { vert: [] } }] },
        { format: 1, name: "b", datasets: {}, visuals: {}, controls: "not an object", tabs: [{ name: "T", layout: { vert: [] } }] },
        { format: 1, name: 42, datasets: {}, visuals: {}, tabs: [{ name: "T", layout: { vert: [] } }] },
        { format: "1", name: "b", datasets: {}, visuals: {}, tabs: [{ name: "T", layout: { vert: [] } }] }
    ]
    i = 0
    while i < count(wrong_types)
        got = gdash_record.check(wrong_types[i])
        s = gdash_test.ok(s, count(got.errors) >= 0, "wrong-typed record " + string(i) + " is judged without raising")
        i += 1
    end while

    ' A dataset and a visual whose bodies are the wrong type entirely.
    s = gdash_test.ok(s, count(gdash_record.check({ format: 1, name: "b", datasets: { d1: "not an object" }, visuals: {}, tabs: [{ name: "T", layout: { vert: [] } }] }).errors) > 0, "a dataset that is a string is refused")
    s = gdash_test.ok(s, count(gdash_record.check({ format: 1, name: "b", datasets: {}, visuals: { v1: 7 }, tabs: [{ name: "T", layout: { vert: [] } }] }).errors) > 0, "a visual that is a number is refused")

    ' --- depth. The layout walk recurses, so nesting is the input that turns
    ' a validator into a stack overflow. Refusing is fine; crashing is not.
    deep = { visual: "v1" }
    d = 0
    while d < 400
        deep = { vert: [deep] }
        d += 1
    end while
    nested = { format: 1, name: "b", datasets: { d1: { profile: "p", sql: "select 1" } },
               visuals: { v1: { dataset: "d1", sql: "select a, b from d1", encoding: { mark: "bar", x: "a", y: "b" } } },
               tabs: [{ name: "T", layout: deep }] }
    got_deep = gdash_record.check(nested)
    s = gdash_test.ok(s, count(got_deep.errors) >= 0, "a layout nested 400 deep is judged rather than fatal")

    ' --- names: empty, unicode, whitespace, and a NUL ---------------------
    ' `select` is NOT in this list, and neither is a name carrying a NUL --
    ' see the two assertions after the loop. Both were in the first draft, and
    ' both were wrong about gdash rather than finding something wrong with it.
    odd_names = ["", " ", "  ", "reg" + chr(233) + "ion", "1", "-", "a.b", "a-b", "a b"]
    i = 0
    while i < count(odd_names)
        r = { format: 1, name: "b", datasets: {}, visuals: {}, tabs: [{ name: "T", layout: { vert: [] } }] }
        ds = {}
        ds[odd_names[i]] = { profile: "p", sql: "select 1" }
        r["datasets"] = ds
        got = gdash_record.check(r)
        s = gdash_test.ok(s, count(got.errors) > 0, "a dataset named <" + odd_names[i] + "> is refused as an identifier")
        i += 1
    end while

    ' A dataset name that is a SQL KEYWORD is accepted. `select` is a legal
    ' identifier lexically, and it becomes a table name -- so a visual reading
    ' `from select` fails at query time with a sqlite syntax error rather than
    ' at load time with a message about the record. Recorded as a finding
    ' rather than fixed: a keyword list is a policy gdash would own forever,
    ' it is dialect-specific, and the failure is immediate and visible on the
    ' author's own first refresh. Asserted so the decision is visible.
    kw = { format: 1, name: "b", datasets: {}, visuals: {}, tabs: [{ name: "T", layout: { vert: [] } }] }
    kw_ds = {}
    kw_ds["select"] = { profile: "p", sql: "select 1" }
    kw["datasets"] = kw_ds
    s = gdash_test.eq(s, count(gdash_record.check(kw).errors), 0, "a dataset named for a SQL keyword is accepted, by decision")

    ' A NUL inside a record KEY now survives, and the assertion is kept to
    ' pin that. It used to fail: keys() returned the key truncated at the NUL
    ' (G6-16), so a dataset the author named "a\0b" was really named "a" by
    ' the time anything validated it -- legal, and not what was written. Fixed
    ' in the platform after 36cb538 made strings binary-safe; the last place
    ' where a NUL still changed a value silently is now closed.
    '
    ' Two keys differing only past a NUL must also stay two keys, because
    ' truncation would have made them one and the second would have won.
    nul_key = {}
    nul_key["a" + chr(0) + "b"] = 1
    s = gdash_test.eq(s, len(keys(nul_key)[0]), 3, "a record key keeps its NUL and everything after it")
    s = gdash_test.eq(s, nul_key["a" + chr(0) + "b"], 1, "and reads back under the whole key")
    nul_key["a"] = 2
    s = gdash_test.eq(s, count(keys(nul_key)), 2, "a key that is the truncation is a different key")
    s = gdash_test.eq(s, nul_key["a" + chr(0) + "b"], 1, "and setting it does not overwrite the longer one")

    ' --- volume: many of everything, and it must still finish -------------
    many = { format: 1, name: "b", datasets: {}, visuals: {}, controls: {}, params: {}, tabs: [] }
    big_ds = {}
    big_vis = {}
    j = 0
    while j < 9
        big_ds["d" + string(j)] = { profile: "p", sql: "select 1" }
        j += 1
    end while
    j = 0
    while j < 200
        big_vis["v" + string(j)] = { dataset: "d0", sql: "select a, b from d0", encoding: { mark: "bar", x: "a", y: "b" } }
        j += 1
    end while
    many["datasets"] = big_ds
    many["visuals"] = big_vis
    many["tabs"] = [{ name: "T", layout: { vert: [] } }]
    big = gdash_record.check(many)
    s = gdash_test.eq(s, count(big.errors), 0, "nine datasets and two hundred visuals validate cleanly")

    ' --- a record that is not a record at all ------------------------------
    s = gdash_test.ok(s, count(gdash_record.check(nothing).errors) > 0, "a record of `nothing` is refused")

    exit(gdash_test.report(s))
end program
