' The limits a refresh meets (GDASH-16), through real refreshes: the dataset
' ceiling, the disk quota before the fetch and again before the swap, and the
' refresh slots -- held from another process, as a running refresh holds
' them. Every refusal leaves the live dataset as it was.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_sched from "../src/gdash_sched.bas"
    load gdash_limits from "../src/gdash_limits.bas"

    s = gdash_test.suite("limits_refresh")
    root = args[0]
    p = gdash_paths.roles(root)
    made = gdash_paths.ensure_dir(p.config_dir)
    orders = { kind: "fixture", path: "fixtures/orders.json" }
    moved = { kind: "fixture", path: "fixtures/orders_moved.json" }
    rec = { format: 1, name: "l", access: "open",
            datasets: { orders: { profile: "w", sql: "select region, month, amount from orders", refresh: "manual" } },
            params: {}, visuals: {}, tabs: [{ name: "L", layout: { vert: [] } }] }
    db = gdash_paths.stage_db(p, "l", "draft")
    lf {file} = gdash_paths.limits_file(p)
    statepath = gdash_paths.dataset_state(p, "l", "draft", "orders")

    ' --- the ceiling: rows x columns, refused before anything is written ---
    write(lf, encode({ format: 1, root: { max_cells: 10 } }))
    big = gdash_refresh.run(p, "l", "draft", rec, "orders", orders, "manual")
    s = gdash_test.ok(s, not big.ok, "a dataset above the ceiling is refused")
    s = gdash_test.contains_text(s, big.message, "above this site's ceiling of 10", "naming the ceiling")
    s = gdash_test.contains_text(s, big.message, "cells", "in the unit it is counted in")
    s = gdash_test.ok(s, not gdash_store.has_dataset(db, "orders") and not gdash_store.has_staging(db, "orders"), "and nothing was written, staging or live")

    write(lf, encode({ format: 1 }))
    first = gdash_refresh.run(p, "l", "draft", rec, "orders", orders, "manual")
    s = gdash_test.ok(s, first.ok, "under the ceiling it refreshes -- " + first.message)
    n0 = gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n
    ' What the store says the root holds, once its database has closed
    ' (linger is 0 here): the dataset's tables, and no logs (gbasic bc694e29).
    sleep(0.5)
    split = gdash_limits.disk_split(p)
    s = gdash_test.ok(s, split.tables > 0, "the root's disk is split into its datasets' tables")
    s = gdash_test.eq(s, split.logs, 0, "and a closed database holds no logs")

    ' --- the memory limit (gbasic B1): a child that runs out dies alone ---
    ' 16 MB is well above where this interpreter can start (gbasic measured
    ' its floor at about 3.5 MB, and it varies by build), and well below what
    ' 40,000 rows need: the child starts, grows, and fails an allocation.
    ' The message is only given for SIGABRT under a limit, so a child that
    ' could not start at all (exit 127) fails this test instead of passing it.
    grown = []
    for i = 1 to 40000
        grown = append(grown, ["region-" + string(i), "2026-01", string(i) + ".25"])
    next
    bigpath = root + "/orders_big.json"
    write({file}bigpath, encode({ columns: ["region", "month", "amount"], rows: grown }))
    write(lf, encode({ format: 1, root: { refresh_memory: 16000000 } }))
    sleep(1.1)
    oom = gdash_refresh.run(p, "l", "draft", rec, "orders", { kind: "fixture", path: bigpath }, "manual")
    s = gdash_test.ok(s, not oom.ok, "a refresh child past its memory limit fails")
    s = gdash_test.contains_text(s, oom.message, "ran out of its memory limit", "and the refresh says it ran out of memory -- " + oom.message)
    s = gdash_test.eq(s, gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n, n0, "the server, and the live data, are untouched")
    write(lf, encode({ format: 1 }))

    ' --- the quota, before the fetch: a site already over it fetches nothing ---
    write(lf, encode({ format: 1, root: { disk_bytes: 1 } }))
    sleep(1.1)
    q1 = gdash_refresh.run(p, "l", "draft", rec, "orders", moved, "manual")
    s = gdash_test.ok(s, not q1.ok, "a site over its disk quota is refused a refresh")
    s = gdash_test.contains_text(s, q1.message, "over its disk quota", "saying so")
    s = gdash_test.eq(s, gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n, n0, "and the previous data is what is served")
    s = gdash_test.contains_text(s, gdash_sched.read_state(statepath).last_error, "disk quota", "the dataset's state records why")

    ' --- the quota, after the fetch: new data that would take it over ---
    ' A quota just above what the site holds now passes the first check; the
    ' staging table, beside the live one, takes it over, and the swap is
    ' refused with the staging table discarded.
    used = gdash_limits.disk_used(p)
    write(lf, encode({ format: 1, root: { disk_bytes: used + 64 } }))
    sleep(1.1)
    q2 = gdash_refresh.run(p, "l", "draft", rec, "orders", moved, "manual")
    s = gdash_test.ok(s, not q2.ok, "a refresh whose new data would take the site over its quota is refused")
    s = gdash_test.eq(s, gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n, n0, "before the swap: the old data is still live")
    s = gdash_test.ok(s, not gdash_store.has_staging(db, "orders"), "and the new data is not left behind")

    ' --- the slots: none free is DEFERRED, not failed ---
    write(lf, encode({ format: 1, root: { refresh_children: 1 } }))
    marker = root + "/held"
    hold = process.start({ command: process.self().interpreter, args: ["tests/hold_slots.bas", marker, "30", gdash_paths.slot_file(p, "root", 0)] })
    t0 = monotonic()
    while not gdash_paths.path_exists(marker) and monotonic() - t0 < 10
        sleep(0.05)
    end while
    s = gdash_test.ok(s, gdash_paths.path_exists(marker), "another process holds this site's one refresh slot")
    before = gdash_sched.read_state(statepath)
    d = gdash_refresh.run(p, "l", "draft", rec, "orders", moved, "manual")
    s = gdash_test.ok(s, d.ok and default(d["deferred"], false), "a refresh with no free slot is deferred -- " + d.message)
    s = gdash_test.contains_text(s, d.message, "this site is already running 1 refreshes", "saying whose limit is full")
    after = gdash_sched.read_state(statepath)
    s = gdash_test.eq(s, after.last_attempt, before.last_attempt, "and a deferral writes no state: it is neither an attempt nor a failure")
    mf {file} = marker
    delete(mf)
    gone = process.wait(hold, 10)

    ' The server's cap is the same, one level up.
    write(lf, encode({ format: 1, server: { refresh_children: 1 } }))
    hold = process.start({ command: process.self().interpreter, args: ["tests/hold_slots.bas", marker, "30", gdash_paths.slot_file(p, "server", 0)] })
    t0 = monotonic()
    while not gdash_paths.path_exists(marker) and monotonic() - t0 < 10
        sleep(0.05)
    end while
    ds = gdash_refresh.run(p, "l", "draft", rec, "orders", moved, "manual")
    s = gdash_test.contains_text(s, ds.message, "the server is already running 1 refreshes", "the server's own cap defers a refresh too")
    delete(mf)
    gone = process.wait(hold, 10)

    ' A slot freed is a slot taken: the deferred refresh now runs.
    sleep(1.1)
    ran = gdash_refresh.run(p, "l", "draft", rec, "orders", moved, "manual")
    s = gdash_test.ok(s, ran.ok and not default(ran["deferred"], false), "once the slot is free, the refresh runs -- " + ran.message)
    s = gdash_test.ok(s, gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n != n0 or ran.unchanged, "and swaps in the new data")
    ' And it gave the slot back: a second process can take it at once.
    hold = process.start({ command: process.self().interpreter, args: ["tests/hold_slots.bas", marker, "1", gdash_paths.slot_file(p, "server", 0)] })
    got = process.wait(hold, 10)
    s = gdash_test.ok(s, got.success, "the refresh released its slots when it finished")
    delete(lf)

    exit(gdash_test.report(s))
end program

