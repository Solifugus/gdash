' A tenant exported and imported (GDASH-17): a backup that has been restored,
' a move to another server, an export that refuses to be imported once it has
' been tampered with, and a deletion that needs a whole export first.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_tenants from "../src/gdash_tenants.bas"
    load gdash_limits from "../src/gdash_limits.bas"
    load gdash_export from "../src/gdash_export.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"
    load gdash_publish from "../src/gdash_publish.bas"
    load gdash_store from "../src/gdash_store.bas"

    s = gdash_test.suite("export")
    root = args[0]

    ' --- a tenant with a published dashboard, data and a limit ---
    bp = gdash_paths.roles(root + "/server")
    made = gdash_paths.ensure_dir(bp.config_dir)
    c = gdash_tenants.create_tenant(bp, "acme", ["acme.test"], root + "/tenants")
    s = gdash_test.ok(s, c.ok, "a tenant to export -- " + c.message)
    tp = gdash_paths.roles(c.root)
    profiles = { o: { kind: "fixture", path: "fixtures/orders.json" } }
    write({file}gdash_paths.connections_file(tp), encode(profiles))
    rec = { format: 1, name: "sales", view_groups: ["staff"],
            datasets: { orders: { profile: "o", sql: "select region, month, amount from orders", refresh: "manual" } },
            params: {}, visuals: {}, tabs: [{ name: "T", layout: { vert: [] } }] }
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(tp, "sales"))
    write({file}gdash_paths.record_file(tp, "sales"), encode(rec))
    r = gdash_refresh.run_together(tp, "sales", "draft", rec, ["orders"], profiles, "manual")
    s = gdash_test.ok(s, r.ok, "its draft refreshes -- " + r.message)
    pub = gdash_publish.publish(tp, "sales")
    s = gdash_test.ok(s, pub.ok, "and publishes, carrying the data -- " + pub.message)
    lim = gdash_limits.set_tenant_limit(bp, "acme", "disk_bytes", "5000000")
    s = gdash_test.ok(s, lim.ok, "and has a limit of its own -- " + lim.message)
    pdb = gdash_paths.stage_db(tp, "sales", "published")
    n0 = gdash_store.select_rows(pdb, "select count(*) as n from orders", {}).rows[0].n

    ' --- export, live ---
    ex = root + "/exports/acme"
    e1 = gdash_export.export_tenant(bp, "acme", ex, true)
    s = gdash_test.ok(s, e1.ok, "a tenant exports -- " + e1.message)
    s = gdash_test.ok(s, e1.datasets >= 2, "with both its databases, draft and published, by backup")
    s = gdash_test.ok(s, gdash_paths.path_exists(ex + "/manifest.json"), "and a manifest, written last")
    s = gdash_test.eq(s, permissions({dir}ex).mode, "0700", "an export holds credentials, so it is the owner's alone")
    s = gdash_test.eq(s, permissions({file}(ex + "/root/etc/connections.json")).mode, "0600", "and so is every file in it")
    s = gdash_test.eq(s, permissions({file}(ex + "/root/cache/sales/published/data.gsql/db")).mode, "0600", "the dataset copies included")
    s = gdash_test.ok(s, not gdash_paths.path_exists(ex + "/root/run"), "run/ -- sessions and counters -- is not exported")
    man = decode(read({file}(ex + "/manifest.json")))
    s = gdash_test.eq(s, man["entry"]["limits"]["disk_bytes"], 5000000, "its registry entry travels with it, limits included")
    s = gdash_test.eq(s, man["files"][0]["path"], "lib/dashboards/sales/current", "the pointer was copied first, before the snapshots it names")
    s = gdash_test.ok(s, not gdash_export.export_tenant(bp, "acme", ex, true).ok, "an export never writes into a directory that holds something")
    s = gdash_test.ok(s, gdash_export.check_export(ex).ok, "a whole export checks clean")

    ' --- an export that has been changed is refused, and nothing is written ---
    cf {file} = ex + "/root/etc/connections.json"
    good = read(cf)
    write(cf, good + " ")
    bad = gdash_export.check_export(ex)
    s = gdash_test.ok(s, not bad.ok, "an export with a changed file is refused")
    s = gdash_test.contains_text(s, join(bad.errors, "; "), "etc/connections.json does not match the manifest", "naming the file")
    write(cf, good)
    write({file}(ex + "/root/etc/extra.json"), "{}")
    s = gdash_test.contains_text(s, join(gdash_export.check_export(ex).errors, "; "), "etc/extra.json is in the export but not in its manifest", "and a file the manifest does not name")
    delete({file}(ex + "/root/etc/extra.json"))
    mf {file} = ex + "/manifest.json"
    mtext = read(mf)
    newer = man
    newer["stamp_format"] = 99
    write(mf, encode(newer))
    s = gdash_test.contains_text(s, join(gdash_export.check_export(ex).errors, "; "), "newer than this build's 1", "and a tenant newer than this build reads")
    write(mf, mtext)

    ' --- import on the same server, as another id ---
    i1 = gdash_export.import_tenant(bp, ex, "", [])
    s = gdash_test.ok(s, not i1.ok, "importing over a tenant that exists is refused")
    s = gdash_test.contains_text(s, i1.message, "nothing was written", "and writes nothing")
    i2 = gdash_export.import_tenant(bp, ex, "acme2", [])
    s = gdash_test.ok(s, not i2.ok and not gdash_paths.path_exists(i2.root), "keeping hosts another tenant has is refused, before a byte is written")
    i3 = gdash_export.import_tenant(bp, ex, "acme2", ["acme2.test"])
    s = gdash_test.ok(s, i3.ok, "an import as a new id, with its own host -- " + i3.message)
    t2 = gdash_tenants.roles_for(bp, "acme2")
    s = gdash_test.ok(s, t2.ok, "is registered")
    p2 = t2.p
    st2 = decode(read({file}gdash_paths.tenant_stamp(p2)))
    s = gdash_test.eq(s, st2["tenant"], "acme2", "its stamp names the id it was imported as")
    s = gdash_test.eq(s, gdash_limits.for_root(p2).disk_bytes, 5000000, "and its limits came with it")
    s = gdash_test.eq(s, gdash_paths.publication(p2, "sales").snapshot, gdash_paths.publication(tp, "sales").snapshot, "the published version is the one that was live")
    s = gdash_test.eq(s, gdash_store.select_rows(gdash_paths.stage_db(p2, "sales", "published"), "select count(*) as n from orders", {}).rows[0].n, n0, "with its data, served without a refresh")
    s = gdash_test.eq(s, permissions({dir}p2.root).mode, "0700", "closed to other users like any tenant")
    s = gdash_test.ok(s, gdash_paths.path_exists(p2.run_dir), "with a fresh run/")
    s = gdash_test.ok(s, not gdash_paths.path_exists(gdash_paths.dir_of(p2.root) + "/.acme2.importing"), "and nothing left of the work directory")

    ' --- a move: another server, its own registry ---
    other = gdash_paths.roles(root + "/other")
    made = gdash_paths.ensure_dir(other.config_dir)
    mv = gdash_export.import_tenant(other, ex, "", [])
    s = gdash_test.ok(s, mv.ok, "the same export moves to another server -- " + mv.message)
    tm = gdash_tenants.roles_for(other, "acme")
    stm = decode(read({file}gdash_paths.tenant_stamp(tm.p)))
    s = gdash_test.eq(s, stm["registry"], real_path(other.config_dir) + "/tenants.json", "its stamp names the NEW server's registry")
    lm = gdash_limits.for_root(tm.p)
    s = gdash_test.ok(s, lm.ok and lm.tenant = "acme", "so its limits are found there, not refused as a copied directory")
    s = gdash_test.eq(s, gdash_tenants.resolve_host(other, "acme.test").tenant, "acme", "and its host resolves there")

    ' --- without data: the datasets refetch ---
    ex2 = root + "/exports/acme-nodata"
    e2 = gdash_export.export_tenant(bp, "acme", ex2, false)
    s = gdash_test.ok(s, e2.ok and e2.datasets = 0, "an export can leave the data behind")
    i4 = gdash_export.import_tenant(bp, ex2, "acme3", ["acme3.test"])
    s = gdash_test.ok(s, i4.ok, "and imports -- " + i4.message)
    p3 = gdash_tenants.roles_for(bp, "acme3").p
    s = gdash_test.ok(s, not gdash_store.has_dataset(gdash_paths.stage_db(p3, "sales", "published"), "orders"), "with its dashboards and no data")
    prec = decode(read({file}gdash_paths.publication(p3, "sales").record_file))
    rr = gdash_refresh.run_together(p3, "sales", "published", prec, ["orders"], profiles, "manual")
    s = gdash_test.ok(s, rr.ok and gdash_store.has_dataset(gdash_paths.stage_db(p3, "sales", "published"), "orders"), "until a refresh fetches it -- " + rr.message)

    ' --- delete for good: only with a whole export of that tenant ---
    pw = gdash_export.purge_tenant(bp, "acme3", ex)
    s = gdash_test.contains_text(s, pw.message, "is an export of 'acme', not 'acme3'", "a purge refuses an export of another tenant")
    ex3 = root + "/exports/acme3"
    e3 = gdash_export.export_tenant(bp, "acme3", ex3, true)
    write({file}(ex3 + "/root/etc/connections.json"), "{}")
    s = gdash_test.contains_text(s, gdash_export.purge_tenant(bp, "acme3", ex3).message, "is not a whole export", "and a damaged one")
    s = gdash_test.ok(s, gdash_tenants.roles_for(bp, "acme3").ok, "leaving the tenant as it was")
    write({file}(ex3 + "/root/etc/connections.json"), encode(profiles))
    pg = gdash_export.purge_tenant(bp, "acme3", ex3)
    s = gdash_test.ok(s, pg.ok, "with a whole export, a tenant is purged -- " + pg.message)
    s = gdash_test.ok(s, not gdash_tenants.roles_for(bp, "acme3").ok and not gdash_paths.path_exists(p3.root), "unregistered, and its directory gone")
    back = gdash_export.import_tenant(bp, ex3, "", [])
    s = gdash_test.ok(s, back.ok, "and that export brings it back -- " + back.message)

    exit(gdash_test.report(s))
end program
