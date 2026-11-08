' Publish carries the draft's data across (G11-11, ruled 2026-11-08) -- per
' dataset, and never blindly: a published dataset may be fresher than the
' draft's, and old data under a new definition is refused.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_record from "../src/gdash_record.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"
    load gdash_publish from "../src/gdash_publish.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_sched from "../src/gdash_sched.bas"

    s = gdash_test.suite("carry")
    root = args[0]
    p = gdash_paths.roles(root)
    orders = { kind: "fixture", path: "fixtures/orders.json" }
    moved = { kind: "fixture", path: "fixtures/orders_moved.json" }

    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "c"))
    rf {file} = gdash_paths.record_file(p, "c")
    rec = { format: 1, name: "c", access: "open",
            datasets: { orders: { profile: "w", sql: "select region, month, amount from orders", refresh: "manual",
                                  columns: { amount: { type: "money", scale: 2 } } },
                        ledger: { profile: "w", sql: "select 1", refresh: "manual" } },
            params: {}, visuals: { total: { dataset: "orders", sql: "select sum(amount) as total from orders",
                                            encoding: { mark: "value", value: "total", format: "currency" } } },
            tabs: [{ name: "C", layout: { vert: [{ visual: "total" }] } }] }
    write(rf, encode(rec))
    ddb = gdash_paths.stage_db(p, "c", "draft")
    pdb = gdash_paths.stage_db(p, "c", "published")
    pv = gdash_paths.version_file(p, "c", "published")

    ' --- first publish: published has nothing, so the draft's is carried ---
    r = gdash_refresh.run(p, "c", "draft", rec, "orders", orders, "manual")
    s = gdash_test.ok(s, r.ok, "the draft refreshes -- " + r.message)
    pub1 = gdash_publish.publish(p, "c")
    s = gdash_test.ok(s, pub1.ok, "the first publish succeeds -- " + pub1.message + " " + join(pub1.errors, "; "))
    s = gdash_test.ok(s, gdash_store.has_dataset(pdb, "orders"), "and the published dashboard HAS data: it is not empty until something refreshes it")
    tot = gdash_store.select_rows(pdb, "select sum(amount) as t from orders", {})
    s = gdash_test.eq(s, money.text(tot.rows[0].t, 2), "4927.05", "the same rows, exactly, money still money")
    s = gdash_test.contains_text(s, join(pub1.notes, " | "), "carried dataset 'orders' from the draft", "the publish says what it carried")
    s = gdash_test.contains_text(s, join(pub1.notes, " | "), "'ledger' has no data yet on either side", "and what it could not")
    s = gdash_test.ok(s, gdash_store.read_version(pv) >= 1, "the published version bumps, so open pages reload onto it")
    dst = gdash_sched.read_state(gdash_paths.dataset_state(p, "c", "draft", "orders"))
    pst = gdash_sched.read_state(gdash_paths.dataset_state(p, "c", "published", "orders"))
    s = gdash_test.eq(s, pst.last_success, dst.last_success, "the published state says when the carried data was fetched")
    s = gdash_test.eq(s, pst.definition, dst.definition, "and under which definition")

    ' --- unchanged, and the published copy is fresher: it is KEPT ---
    ' A draft refreshes only when someone asks; a published dataset may
    ' refresh every few minutes. Republishing a title must not swap fresh
    ' data for stale.
    sleep(1.1)
    rp = gdash_refresh.run(p, "c", "published", rec, "orders", moved, "manual")
    s = gdash_test.ok(s, rp.ok and not rp.unchanged, "the published side refreshes to newer data -- " + rp.message)
    fresh_n = gdash_store.select_rows(pdb, "select count(*) as n from orders", {}).rows[0].n
    rec["visuals"]["total"]["encoding"]["title"] = "Total"
    write(rf, encode(rec))
    pub2 = gdash_publish.publish(p, "c")
    s = gdash_test.ok(s, pub2.ok, "a republish of a title succeeds")
    s = gdash_test.eq(s, gdash_store.select_rows(pdb, "select count(*) as n from orders", {}).rows[0].n, fresh_n, "and leaves the fresher published data in place")
    s = gdash_test.contains_text(s, join(pub2.notes, " | "), "kept the published data for 'orders'", "saying so")

    ' --- unchanged, and the draft is fresher: it is carried ---
    sleep(1.1)
    r2 = gdash_refresh.run(p, "c", "draft", rec, "orders", orders, "manual")
    pub3 = gdash_publish.publish(p, "c")
    s = gdash_test.contains_text(s, join(pub3.notes, " | "), "carried dataset 'orders'", "a draft fetched more recently is carried")
    s = gdash_test.eq(s, gdash_store.select_rows(pdb, "select count(*) as n from orders", {}).rows[0].n, 6, "and its rows are what is served")

    ' --- a changed definition the draft has not fetched: REFUSED ---
    rec["datasets"]["orders"]["sql"] = "select region, month, amount from orders where amount > 0"
    write(rf, encode(rec))
    v_before = gdash_store.read_version(pv)
    pub4 = gdash_publish.publish(p, "c")
    s = gdash_test.ok(s, not pub4.ok, "a new definition the draft never fetched is refused")
    s = gdash_test.contains_text(s, join(pub4.errors, " | "), "dataset 'orders' has a new definition", "naming the dataset")
    s = gdash_test.contains_text(s, join(pub4.errors, " | "), "refresh the draft first", "and what to do")
    s = gdash_test.eq(s, gdash_store.read_version(pv), v_before, "and nothing was carried")

    ' --- once the draft fetches it, the new definition's data is carried ---
    r3 = gdash_refresh.run(p, "c", "draft", rec, "orders", orders, "manual")
    pub5 = gdash_publish.publish(p, "c")
    s = gdash_test.ok(s, pub5.ok, "after the draft refreshes under the new definition, it publishes -- " + join(pub5.errors, "; "))
    s = gdash_test.contains_text(s, join(pub5.notes, " | "), "carried dataset 'orders'", "carrying the data fetched under it")
    s = gdash_test.eq(s, gdash_sched.read_state(gdash_paths.dataset_state(p, "c", "published", "orders")).definition,
                      gdash_sched.definition_of(rec["datasets"]["orders"]), "the published data is the new definition's")

    ' --- a column declaration is part of the definition ---
    rec["datasets"]["orders"]["columns"]["amount"]["currency"] = "EUR"
    write(rf, encode(rec))
    pub6 = gdash_publish.publish(p, "c")
    s = gdash_test.ok(s, not pub6.ok, "changing a money column's currency is a new definition too")

    exit(gdash_test.report(s))
end program
