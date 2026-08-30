program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"

    s = gdash_test.suite("paths")
    root = args[0]

    ' --root collapses every role under one directory (design §6).
    p = gdash_paths.roles(root)
    s = gdash_test.eq(s, p.mode, "root", "root mode")
    s = gdash_test.eq(s, p.config_dir, root + "/etc", "config_dir under root")
    s = gdash_test.eq(s, p.state_dir, root + "/lib", "state_dir under root")
    s = gdash_test.eq(s, p.cache_dir, root + "/cache", "cache_dir under root")
    s = gdash_test.eq(s, p.log_dir, root + "/log", "log_dir under root")
    s = gdash_test.eq(s, p.run_dir, root + "/run", "run_dir under root")

    ' FHS when no root is given.
    f = gdash_paths.roles("")
    s = gdash_test.eq(s, f.mode, "fhs", "fhs mode")
    s = gdash_test.eq(s, f.state_dir, "/var/lib/gdash", "fhs state_dir")
    s = gdash_test.eq(s, f.cache_dir, "/var/cache/gdash", "fhs cache_dir")

    ' Precious state and disposable cache never share a directory (design §6).
    s = gdash_test.ok(s, f.state_dir != f.cache_dir, "state and cache are separate roots")

    ' --root parsed out of argv.
    a = gdash_paths.from_args(["--root", "/tmp/x", "serve"])
    s = gdash_test.eq(s, a.state_dir, "/tmp/x/lib", "from_args reads --root")
    b = gdash_paths.from_args(["serve"])
    s = gdash_test.eq(s, b.mode, "fhs", "from_args defaults to fhs")

    ' Role gdash_paths.
    s = gdash_test.eq(s, gdash_paths.record_file(p, "sales"), root + "/lib/dashboards/sales/draft.json", "record_file")
    s = gdash_test.eq(s, gdash_paths.dataset_db(p, "sales", "draft", "orders"), root + "/cache/sales/draft/orders.db", "dataset_db")
    s = gdash_test.eq(s, gdash_paths.dataset_staging(p, "sales", "draft", "orders"), root + "/cache/sales/draft/orders__staging.db", "dataset_staging")
    s = gdash_test.eq(s, gdash_paths.version_file(p, "sales", "draft"), root + "/cache/sales/draft/version", "version_file")

    ' The staging file sits beside its live file, so the swap is a same-
    ' filesystem rename (atomic_replace refuses to cross devices).
    s = gdash_test.eq(s, gdash_paths.data_dir(p, "sales", "draft"), root + "/cache/sales/draft", "staging shares live dir")

    ' Draft and published data never share a directory (design §7).
    s = gdash_test.eq(s, gdash_paths.data_dir(p, "sales", "published"), root + "/cache/sales/published", "published data_dir")
    s = gdash_test.ok(s, gdash_paths.dataset_db(p, "sales", "draft", "orders") != gdash_paths.dataset_db(p, "sales", "published", "orders"), "draft and published datasets are different files")
    s = gdash_test.eq(s, gdash_paths.dataset_state(p, "sales", "published", "orders"), root + "/cache/sales/published/orders.state.json", "dataset_state")
    s = gdash_test.eq(s, gdash_paths.dataset_lock(p, "sales", "draft", "orders"), root + "/cache/sales/draft/orders.lock", "dataset_lock")

    ' Publication: no `current` means draft, which is every dashboard until
    ' GDASH-3 ships publish.
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "pubtest"))
    pub = gdash_paths.publication(p, "pubtest")
    s = gdash_test.eq(s, pub.mode, "draft", "no pointer means draft")
    s = gdash_test.ok(s, not pub.published, "no pointer means not published")
    s = gdash_test.eq(s, pub.record_file, gdash_paths.record_file(p, "pubtest"), "draft serves draft.json")

    ' A pointer naming a real snapshot publishes it.
    made = gdash_paths.ensure_dir(gdash_paths.snapshot_dir(p, "pubtest"))
    sf {file} = gdash_paths.snapshot_file(p, "pubtest", "0001.json")
    write(sf, "{}")
    cf {file} = gdash_paths.current_pointer(p, "pubtest")
    write(cf, "0001.json" + chr(10))
    pub = gdash_paths.publication(p, "pubtest")
    s = gdash_test.eq(s, pub.mode, "published", "a pointer to a real snapshot publishes")
    s = gdash_test.eq(s, pub.record_file, gdash_paths.snapshot_file(p, "pubtest", "0001.json"), "published serves the snapshot")

    ' A pointer to a snapshot that is not there is not a published dashboard;
    ' it is a broken one, and serving the draft instead of nothing is the
    ' stale-but-coherent posture applied to the record.
    write(cf, "9999.json")
    s = gdash_test.eq(s, gdash_paths.publication(p, "pubtest").mode, "draft", "a dangling pointer falls back to draft")

    ' The pointer names a snapshot, never a path. Otherwise `current` holding
    ' "../../../etc/gdash/connections.json" would read credentials as a record.
    write(cf, "../../../etc/passwd")
    s = gdash_test.eq(s, gdash_paths.publication(p, "pubtest").mode, "draft", "a pointer with a path separator is refused")

    ' ensure_dir is idempotent and creates parents.
    deep = root + "/cache/sales/draft/nested/deeper"
    s = gdash_test.ok(s, gdash_paths.ensure_dir(deep), "ensure_dir creates parents")
    s = gdash_test.ok(s, gdash_paths.path_exists(deep), "created dir exists")
    s = gdash_test.ok(s, gdash_paths.ensure_dir(deep), "ensure_dir is idempotent")
    s = gdash_test.ok(s, not gdash_paths.path_exists(root + "/cache/sales/draft/absent"), "missing path reports absent")

    exit(gdash_test.report(s))
end program
