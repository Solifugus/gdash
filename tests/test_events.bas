' The operator's stream and tenant migration (GDASH-17). An operator with many
' tenants sees sign-ins, failures, refusals and spend for all of them in one
' log, with each tenant named and nothing private carried; and an upgrade
' says what every tenant's stamp is.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_tenants from "../src/gdash_tenants.bas"
    load gdash_audit from "../src/gdash_audit.bas"
    load gdash_spend from "../src/gdash_spend.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"

    s = gdash_test.suite("events")
    root = args[0]
    bp = gdash_paths.roles(root + "/server")
    made = gdash_paths.ensure_dir(bp.config_dir)
    c = gdash_tenants.create_tenant(bp, "acme", ["acme.test"], root + "/tenants")
    tp = gdash_paths.roles(c.root)
    c2 = gdash_tenants.create_tenant(bp, "globex", ["globex.test"], "")
    gp = gdash_paths.roles(c2.root)
    evf {file} = gdash_paths.events_log(bp)

    ' --- what is forwarded, and what is not ---
    logged = gdash_audit.event(tp, "login.failed", { user: "mallory", provider: "local" })
    logged = gdash_audit.event(gp, "login", { user: "ada" })
    logged = gdash_audit.event(tp, "ask", { dashboard: "sales", user: "bo", question: "what are our margins by client" })
    logged = gdash_audit.event(tp, "access.denied", { dashboard: "sales", user: "bo" })
    lines = []
    for each ln in read_lines(evf)
        lines = append(lines, decode(ln))
    next
    s = gdash_test.eq(s, count(lines), 3, "the operator's kinds reach the base's events.log; a routine denial stays in the tenant's own log")
    s = gdash_test.eq(s, lines[0]["tenant"], "acme", "each line names its tenant")
    s = gdash_test.eq(s, lines[0]["event"], "login.failed", "and its event")
    s = gdash_test.eq(s, lines[1]["tenant"], "globex", "from every tenant on the server")
    s = gdash_test.ok(s, is_unknown(lines[2]["question"]), "a question's text is the tenant's data, and is not forwarded")
    s = gdash_test.eq(s, lines[2]["dashboard"], "sales", "though that one was asked is")
    s = gdash_test.contains_text(s, read({file}gdash_paths.audit_log(tp)), "what are our margins by client", "the tenant's own audit log keeps everything, as before")

    ' --- a single root has no second log ---
    single = gdash_paths.roles(root + "/single")
    made = gdash_paths.ensure_dir(single.config_dir)
    logged = gdash_audit.event(single, "login.failed", { user: "x" })
    s = gdash_test.ok(s, not gdash_paths.path_exists(gdash_paths.events_log(single)), "a single root's audit log is already the operator's")

    ' --- a refresh that fails, and money spent ---
    profiles = { down: { kind: "fixture", path: "fixtures/orders_unavailable.json" } }
    rec = { format: 1, name: "sales", datasets: { orders: { profile: "down", sql: "select region, month, amount from orders", refresh: "manual" } },
            params: {}, visuals: {}, tabs: [{ name: "T", layout: { vert: [] } }] }
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(tp, "sales"))
    r = gdash_refresh.run_together(tp, "sales", "draft", rec, ["orders"], profiles, "manual")
    s = gdash_test.ok(s, not r.ok, "a refresh whose source is down fails")
    profile = { price: { currency: "USD", input: "3.00", output: "15.00" } }
    ch = gdash_spend.charge(tp, profile, { input: 1000, output: 200 }, 0)
    text = read(evf)
    s = gdash_test.contains_text(s, text, "\"event\":\"refresh.unit_failed\"", "the refresh failure reaches the operator")
    sp = unknown
    for each ln in read_lines(evf)
        e = decode(ln)
        if e["event"] = "spend" then
            sp = e
        end if
    next
    s = gdash_test.ok(s, not is_unknown(sp), "so does each question's charge")
    s = gdash_test.eq(s, sp["cost"], "0.006000", "as exact money: 1,000 in at 3.00 and 200 out at 15.00 a million")
    s = gdash_test.eq(s, sp["tenant"], "acme", "against the tenant that spent it")
    s = gdash_test.ok(s, is_unknown(sp["price"]) and is_unknown(sp["key"]), "and never the profile, which holds the key")

    ' --- migrate: what each tenant's stamp is ---
    m1 = gdash_tenants.migrate(bp, ["acme", "globex"])
    s = gdash_test.eq(s, m1[0].status, "current", "a tenant at this build's format is current")
    sf {file} = gdash_paths.tenant_stamp(gp)
    good = read(sf)
    st = decode(good)
    st["format"] = 2
    write(sf, encode(st))
    m2 = gdash_tenants.migrate(bp, ["globex"])
    s = gdash_test.eq(s, m2[0].status, "newer", "one stamped newer than this build is refused")
    s = gdash_test.contains_text(s, m2[0].message, "needs a newer gdash", "saying what to do")
    st["format"] = 0
    write(sf, encode(st))
    s = gdash_test.eq(s, gdash_tenants.migrate(bp, ["globex"])[0].status, "failed", "an older one with no step to take it forward fails, rather than being stamped current")
    s = gdash_test.eq(s, decode(read(sf))["format"], 0, "and its stamp is left as it was")
    write(sf, "{ torn")
    s = gdash_test.eq(s, gdash_tenants.migrate(bp, ["globex"])[0].status, "unreadable", "a stamp that does not read is said so")
    write(sf, good)
    s = gdash_test.eq(s, gdash_tenants.migrate(bp, ["nobody"])[0].status, "unreadable", "and so is a tenant that is not registered")

    exit(gdash_test.report(s))
end program
