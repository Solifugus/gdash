' The limits (GDASH-16): where they are found, what they default to, how they
' fail closed, the disk quota's arithmetic, and the model budget's meter.
' The refresh slots and the dataset ceiling are exercised through a real
' refresh, in test_limits_refresh.bas.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_tenants from "../src/gdash_tenants.bas"
    load gdash_limits from "../src/gdash_limits.bas"
    load gdash_spend from "../src/gdash_spend.bas"

    s = gdash_test.suite("limits")
    root = args[0]

    ' --- a single root: the intranet's defaults ---
    single = gdash_paths.roles(root + "/single")
    made = gdash_paths.ensure_dir(single.config_dir)
    l1 = gdash_limits.for_root(single)
    s = gdash_test.ok(s, l1.ok and l1.scope = "root", "a root with no stamp is a single deployment")
    s = gdash_test.ok(s, l1.open_access, "where access: open stays the per-dashboard opt-in it always was")
    s = gdash_test.eq(s, l1.disk_bytes, "none", "with no disk quota")
    s = gdash_test.eq(s, l1.model_budget, "none", "and no model budget")
    s = gdash_test.eq(s, l1.max_cells, 1000000, "but the measured dataset ceiling applies to everyone")
    s = gdash_test.eq(s, l1.server_children, 4, "as does the server's refresh cap")
    s = gdash_test.eq(s, l1.disk_reserve, 1073741824, "and its disk reserve: a gibibyte the volume keeps available")
    s = gdash_test.eq(s, gdash_limits.child_memory(l1), 134217728 + 1000000 * 600, "a refresh child's memory is derived from the ceiling: baseline plus twice 300 bytes a cell")
    s = gdash_test.eq(s, gdash_limits.child_memory({ refresh_memory: 5000, max_cells: 1 }), 5000, "unless the operator names a number")
    s = gdash_test.ok(s, gdash_limits.parse_value("refresh_memory", "auto").ok, "auto is a refresh_memory")

    lf {file} = gdash_paths.limits_file(single)
    write(lf, encode({ format: 1, server: { refresh_children: 6, disk_reserve: 2048 }, root: { disk_bytes: 5000, max_cells: 10 } }))
    l2 = gdash_limits.for_root(single)
    s = gdash_test.eq(s, l2.disk_bytes, 5000, "limits.json overrides a default")
    s = gdash_test.eq(s, l2.server_children, 6, "including the server's")
    s = gdash_test.eq(s, l2.disk_reserve, 2048, "both of them")
    s = gdash_test.ok(s, l2.open_access, "and leaves the rest as they were")

    write(lf, encode({ format: 1, root: { disk_bytes: -1, colour: "red", model_budget: { amount: 25, currency: "USD" } } }))
    l3 = gdash_limits.for_root(single)
    s = gdash_test.ok(s, not l3.ok, "a limits file with a wrong value is refused")
    s = gdash_test.ok(s, not l3.open_access and l3.refresh_children = 0, "and the answer is the CLOSED one, not the defaults")
    s = gdash_test.contains_text(s, l3.message, "'disk_bytes' must be a whole number of bytes", "naming the value")
    s = gdash_test.contains_text(s, l3.message, "sets 'colour'; the limits are", "and an unknown limit")
    s = gdash_test.contains_text(s, l3.message, "amount must be decimal text", "and a budget written as a number, which money would not read exactly")
    write(lf, encode({ format: 1, server: { disk_reserve: -5 } }))
    l4 = gdash_limits.for_root(single)
    s = gdash_test.ok(s, not l4.ok, "a negative disk reserve is refused")
    s = gdash_test.contains_text(s, l4.message, "'disk_reserve' must be a whole number of bytes", "naming it")
    write(lf, encode({ format: 1, server: { disk_reserve: "none" } }))
    s = gdash_test.eq(s, gdash_limits.for_root(single).disk_reserve, "none", "and none switches it off")
    write(lf, "{ not json")
    s = gdash_test.ok(s, not gdash_limits.for_root(single).ok, "a limits file that does not parse is refused too")
    delete(lf)

    ' --- a tenant: found from its own root, closed by default ---
    bp = gdash_paths.roles(root + "/server")
    made = gdash_paths.ensure_dir(bp.config_dir)
    base = root + "/tenants"
    c = gdash_tenants.create_tenant(bp, "acme", ["acme.test"], base)
    s = gdash_test.ok(s, c.ok, "a tenant is created -- " + c.message)
    tp = gdash_paths.roles(c.root)
    stamp = decode(read({file}gdash_paths.tenant_stamp(tp)))
    s = gdash_test.eq(s, stamp["registry"], real_path(bp.config_dir) + "/tenants.json", "its stamp names the registry that governs it")
    lt = gdash_limits.for_root(tp)
    s = gdash_test.ok(s, lt.ok and lt.scope = "tenant" and lt.tenant = "acme", "its root, reached with nothing but the root, is known to be that tenant")
    s = gdash_test.ok(s, not lt.open_access, "a tenant may NOT publish to the world unless granted")
    s = gdash_test.eq(s, lt.disk_bytes, 1073741824, "has a disk quota")
    s = gdash_test.eq(s, lt.refresh_children, 2, "a refresh cap of its own")
    s = gdash_test.eq(s, string(lt.model_budget["amount"]), "0.00", "and no model budget until one is set")

    w = gdash_limits.set_tenant_limit(bp, "acme", "open_access", "true")
    s = gdash_test.ok(s, w.ok, "the operator grants open access -- " + w.message)
    s = gdash_test.ok(s, gdash_limits.for_root(tp).open_access, "and the tenant has it")
    w = gdash_limits.set_tenant_limit(bp, "acme", "model_budget", "25.00USD")
    s = gdash_test.ok(s, w.ok, "a budget is set as amount and currency")
    s = gdash_test.eq(s, gdash_limits.shown("model_budget", gdash_limits.for_root(tp).model_budget), "25.00 USD a month", "and shown as one")
    bad = gdash_limits.set_tenant_limit(bp, "acme", "disk_bytes", "lots")
    s = gdash_test.ok(s, not bad.ok, "a limit that is not its kind is refused")
    s = gdash_test.ok(s, not gdash_limits.set_tenant_limit(bp, "acme", "speed", "9").ok, "and a name that is not a limit")
    s = gdash_test.ok(s, not gdash_limits.set_tenant_limit(bp, "acme", "model_budget", "25").ok, "and a budget with no currency")

    ' Fail closed when the stamp and the registry disagree. A stamped
    ' directory copied out of the base is not that tenant.
    copy = root + "/copied"
    cp = process.run({ command: "cp", args: ["-r", c.root, copy] })
    cl = gdash_limits.for_root(gdash_paths.roles(copy))
    s = gdash_test.ok(s, not cl.ok and not cl.open_access, "a copied tenant directory gets the CLOSED limits, not acme's")
    s = gdash_test.contains_text(s, cl.message, "places that tenant elsewhere", "saying why")
    gone = gdash_tenants.remove_tenant(bp, "acme")
    s = gdash_test.ok(s, not gdash_limits.for_root(tp).ok, "and a tenant no longer in the registry is closed")

    ' --- disk ---
    d = gdash_paths.roles(root + "/disk")
    made = gdash_paths.ensure_dir(d.cache_dir + "/x")
    made = gdash_paths.ensure_dir(d.run_dir)
    made = gdash_paths.ensure_dir(d.state_dir)
    write({file}(d.cache_dir + "/x/a"), repeat("a", 3000))
    write({file}(d.state_dir + "/b"), repeat("b", 1000))
    write({file}(d.run_dir + "/c"), repeat("c", 50000))
    s = gdash_test.eq(s, gdash_limits.disk_used(d), 4000, "disk used counts state, cache and log, nested -- and not run/, which is tmpfs")
    under = gdash_limits.disk_check(d, { disk_bytes: 4000, disk_reserve: "none" })
    s = gdash_test.ok(s, under.ok, "at the quota is within it")
    over = gdash_limits.disk_check(d, { disk_bytes: 3999, disk_reserve: "none" })
    s = gdash_test.ok(s, not over.ok, "a byte over is not")
    s = gdash_test.contains_text(s, over.message, "the previous data is still served", "and the refusal says the old data stands")
    s = gdash_test.ok(s, gdash_limits.disk_check(d, { disk_bytes: "none", disk_reserve: "none" }).ok, "none is no quota")

    ' --- the volume: the reserve every root shares ---
    roomy = gdash_limits.volume_check(d, { scope: "root", disk_reserve: 0 })
    s = gdash_test.ok(s, roomy.ok and roomy.available > 0, "a volume with room is within its reserve, and says what it has")
    full = gdash_limits.disk_check(d, { scope: "root", disk_bytes: "none", disk_reserve: 1000000000000000000 })
    s = gdash_test.ok(s, not full.ok and full.kind = "volume", "a volume below its reserve refuses, even with no quota")
    s = gdash_test.contains_text(s, full.message, "the server is low on disk space (", "saying so")
    s = gdash_test.contains_text(s, full.message, "in reserve); the refresh was refused and the previous data is still served", "with the numbers, for an operator")
    tfull = gdash_limits.volume_check(d, { scope: "tenant", disk_reserve: 1000000000000000000 })
    s = gdash_test.eq(s, tfull.message, "the server is low on disk space; the refresh was refused and the previous data is still served", "a tenant is told the server is short, not how short")
    over2 = gdash_limits.disk_check(d, { scope: "root", disk_bytes: 3999, disk_reserve: 1000000000000000000 })
    s = gdash_test.eq(s, over2.kind, "quota", "over both, the site's own quota is what it is told")
    fresh = gdash_paths.roles(root + "/not_made_yet/r")
    s = gdash_test.ok(s, gdash_limits.volume_check(fresh, { disk_reserve: 0 }).ok, "a root whose cache is not made yet is measured on the volume it will be made on")
    s = gdash_test.ok(s, gdash_limits.volume_check(d, { disk_reserve: "none" }).ok, "none is no reserve")
    nosplit = gdash_limits.disk_split(d)
    s = gdash_test.eq(s, nosplit.tables + nosplit.logs, 0, "a cache directory that holds no database has no tables or logs to report")

    ' --- the model budget ---
    sp = gdash_paths.roles(root + "/spend")
    made = gdash_paths.ensure_dir(sp.state_dir)
    priced = { model: "m", max_tokens: 1000, price: { currency: "USD", input: "3.00", output: "15.00" } }
    unpriced = { model: "m" }
    budget = { model_budget: { amount: "0.05", currency: "USD" } }
    s = gdash_test.ok(s, gdash_spend.check_budget(sp, { model_budget: "none" }, unpriced).ok, "with no budget, any profile may be used")
    nob = gdash_spend.check_budget(sp, { model_budget: { amount: "0.00", currency: "USD" } }, priced)
    s = gdash_test.ok(s, not nob.ok, "a zero budget turns questions off")
    s = gdash_test.contains_text(s, nob.message, "gdash tenant limit", "and says how to turn them on")
    np = gdash_spend.check_budget(sp, budget, unpriced)
    s = gdash_test.ok(s, not np.ok, "under a budget, a profile with no price is refused, not assumed free")
    eur = gdash_spend.check_budget(sp, { model_budget: { amount: "10.00", currency: "EUR" } }, priced)
    s = gdash_test.contains_text(s, eur.message, "there is no exchange rate here", "a price in another currency than the budget is refused")
    s = gdash_test.ok(s, gdash_spend.check_budget(sp, budget, priced).ok, "a priced profile under its budget may ask")

    ' 1000 in at $3/M and 2000 out at $15/M is 0.003 + 0.03 = 0.033.
    c1 = gdash_spend.charge(sp, priced, { input: 1000, output: 2000 }, 0)
    s = gdash_test.eq(s, money.text(c1.cost), "0.033000", "a call costs exactly its tokens at the price")
    led = gdash_spend.read_ledger(sp, gdash_spend.this_month(), "USD")
    s = gdash_test.eq(s, money.text(led.spent), "0.033000", "the ledger holds it exactly")
    s = gdash_test.ok(s, gdash_spend.check_budget(sp, budget, priced).ok, "still under 0.05")
    c2 = gdash_spend.charge(sp, priced, unknown, 4000)
    s = gdash_test.ok(s, c2.estimated, "a call that reported no usage is ESTIMATED")
    s = gdash_test.eq(s, money.text(c2.cost), "0.021000", "high: 2000 in for 4000 characters, and max_tokens out")
    full = gdash_spend.check_budget(sp, budget, priced)
    s = gdash_test.ok(s, not full.ok, "once the month's spend reaches the budget, questions are refused")
    s = gdash_test.contains_text(s, full.message, "0.05 of 0.05 USD", "saying how much of how much")
    led = gdash_spend.read_ledger(sp, gdash_spend.this_month(), "USD")
    s = gdash_test.eq(s, led.calls, 2, "every call is counted")
    s = gdash_test.eq(s, led.estimated, 1, "and the estimated ones are counted apart")
    write({file}gdash_paths.spend_file(sp, gdash_spend.this_month()), "{ torn")
    s = gdash_test.ok(s, not gdash_spend.check_budget(sp, { model_budget: { amount: "100.00", currency: "USD" } }, priced).ok, "a ledger that does not read is not a ledger showing nothing spent")
    jan1 {datetime}= "2026-01-31T23:59:59Z"
    s = gdash_test.eq(s, gdash_spend.month_of(jan1), "2026-01", "a month is the UTC calendar month")

    exit(gdash_test.report(s))
end program
