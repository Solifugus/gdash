' A dashboard refreshed as one (G57): every dataset staged, then all swapped
' in one transaction with one version bump -- and when one fails, none is
' swapped, so the dashboard never shows two extracts at once.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_sched from "../src/gdash_sched.bas"
    load gdash_publish from "../src/gdash_publish.bas"

    s = gdash_test.suite("together")
    root = args[0]
    p = gdash_paths.roles(root)
    profiles = { o: { kind: "fixture", path: "fixtures/orders.json" }, m: { kind: "fixture", path: "fixtures/orders_moved.json" },
                 r: { kind: "fixture", path: "fixtures/regions.json" }, down: { kind: "fixture", path: "fixtures/orders_unavailable.json" } }
    rec = { format: 1, name: "t", access: "open",
            datasets: { orders: { profile: "o", sql: "select region, month, amount from orders", refresh: "manual" },
                        regions: { profile: "r", sql: "select region, label, manager from regions", refresh: "manual" } },
            params: {}, visuals: {}, tabs: [{ name: "T", layout: { vert: [] } }] }
    db = gdash_paths.stage_db(p, "t", "draft")
    vfile = gdash_paths.version_file(p, "t", "draft")
    names = ["orders", "regions"]

    ' --- together: both datasets, one version ---
    u1 = gdash_refresh.run_together(p, "t", "draft", rec, names, profiles, "manual")
    s = gdash_test.ok(s, u1.ok, "a dashboard refreshes as one -- " + u1.message)
    s = gdash_test.eq(s, sort(u1.refreshed), ["orders", "regions"], "every dataset is refreshed")
    s = gdash_test.eq(s, gdash_store.read_version(vfile), 1, "under ONE version bump, so an open page reloads once")
    s = gdash_test.ok(s, gdash_store.has_dataset(db, "orders") and gdash_store.has_dataset(db, "regions"), "both are live")
    s = gdash_test.eq(s, u1.rows["orders"], 6, "each with its rows counted")

    ' --- one fails: NEITHER is swapped ---
    ' orders would move to the newer extract; regions' source is down. A
    ' dashboard with the new orders under the old regions is exactly what
    ' this exists to prevent, so the new orders are held back too.
    sleep(1.1)
    rec["datasets"]["orders"]["profile"] = "m"
    rec["datasets"]["regions"]["profile"] = "down"
    before_reg = gdash_sched.read_state(gdash_paths.dataset_state(p, "t", "draft", "regions"))
    before_ord = gdash_sched.read_state(gdash_paths.dataset_state(p, "t", "draft", "orders"))
    u2 = gdash_refresh.run_together(p, "t", "draft", rec, names, profiles, "manual")
    s = gdash_test.ok(s, not u2.ok, "when one dataset fails, the unit fails")
    s = gdash_test.eq(s, u2.failed, "regions", "naming the one that failed")
    s = gdash_test.contains_text(s, u2.message, "no dataset of 't' was swapped", "and saying nothing was swapped")
    s = gdash_test.eq(s, gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n, 6, "orders still shows the extract regions agrees with")
    s = gdash_test.ok(s, not gdash_store.has_staging(db, "orders"), "and its new data was not left behind")
    s = gdash_test.eq(s, gdash_store.read_version(vfile), 1, "the version did not move")
    after_reg = gdash_sched.read_state(gdash_paths.dataset_state(p, "t", "draft", "regions"))
    after_ord = gdash_sched.read_state(gdash_paths.dataset_state(p, "t", "draft", "orders"))
    s = gdash_test.ok(s, after_reg.last_attempt > before_reg.last_attempt and after_reg.last_error != "", "the failed dataset records its failure")
    s = gdash_test.eq(s, after_ord.last_attempt, before_ord.last_attempt, "and the one held back records nothing -- it did not fail")

    ' --- one changed, one not: one bump, and the unchanged one said so ---
    sleep(1.1)
    rec["datasets"]["regions"]["profile"] = "r"
    u3 = gdash_refresh.run_together(p, "t", "draft", rec, names, profiles, "manual")
    s = gdash_test.ok(s, u3.ok, "with the source back, the unit refreshes -- " + u3.message)
    s = gdash_test.eq(s, u3.refreshed, ["orders"], "the dataset that moved is swapped")
    s = gdash_test.eq(s, u3.unchanged, ["regions"], "the one that did not is reported unchanged")
    s = gdash_test.eq(s, gdash_store.read_version(vfile), 2, "and the version moves once")
    s = gdash_test.eq(s, gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n, 7, "onto the newer extract")
    s = gdash_test.eq(s, gdash_refresh.run_together(p, "t", "draft", rec, names, profiles, "manual").version, 2, "and nothing moving bumps nothing")

    ' --- the store: one transaction, all or nothing ---
    ' Two staging tables, one of them missing at swap time: the rename of the
    ' missing one fails, and the one that was fine is rolled back with it.
    cols = ["region", "n"]
    plan = gdash_store.plan_columns(cols, [["x", "1"]], {})
    w = gdash_store.materialize(db, "orders", plan, [["x", "1"]])
    sa = gdash_store.swap_all(db, ["orders", "nonesuch"])
    s = gdash_test.ok(s, not sa.ok, "a swap of several in which one cannot be made fails")
    s = gdash_test.eq(s, gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n, 7, "and the one that could have been made was rolled back with it")
    cleared = gdash_store.discard_staging(db, "orders")

    ' --- the scheduler: the datasets due on a pass go together ---
    prec = rec
    prec["name"] = "sched"
    prec["datasets"]["orders"] = { profile: "o", sql: "select region, month, amount from orders", refresh: "interval", every: 3600 }
    prec["datasets"]["regions"] = { profile: "r", sql: "select region, label, manager from regions", refresh: "interval", every: 3600 }
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "sched"))
    write({file}gdash_paths.record_file(p, "sched"), encode(prec))
    cf {file} = gdash_paths.connections_file(p)
    made = gdash_paths.ensure_dir(p.config_dir)
    write(cf, encode(profiles))
    pub = gdash_publish.publish(p, "sched")
    s = gdash_test.ok(s, pub.ok, "a scheduled dashboard publishes -- " + pub.message)
    pv = gdash_paths.version_file(p, "sched", "published")
    v0 = gdash_store.read_version(pv)
    ps = gdash_refresh.pass(p)
    s = gdash_test.eq(s, ps.refreshed, 2, "a pass refreshes both due datasets")
    s = gdash_test.eq(s, gdash_store.read_version(pv), v0 + 1, "in one swap: one version for the two")
    s = gdash_test.contains_text(s, join(ps.notes, " | "), "sched.orders: refreshed 6 rows -> version " + string(v0 + 1), "and the notes say so per dataset")

    exit(gdash_test.report(s))
end program
