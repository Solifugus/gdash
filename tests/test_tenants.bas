' The tenant registry's rules (GDASH-15): ids, hosts, the registry's own
' shape, and the containment every resolution rests on.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_tenants from "../src/gdash_tenants.bas"

    s = gdash_test.suite("tenants")
    root = args[0]

    ' --- ids: stricter than a dashboard name, because here the segment IS the tenant ---
    for each good in ["acme", "a", "acme-2", "x1y2"]
        s = gdash_test.ok(s, gdash_tenants.valid_id(good), "'" + good + "' is a tenant id")
    next
    for each bad in ["", "..", ".", "a.b", "a/b", "ACME", "-a", "a-", "a_b", "a b", "a12345678901234567890123456789012345678901"]
        s = gdash_test.ok(s, not gdash_tenants.valid_id(bad), "'" + bad + "' is not")
    next

    ' --- hosts: matched without case, port or a trailing dot ---
    s = gdash_test.eq(s, gdash_tenants.normal_host("ACME.Example.com:8443"), "acme.example.com", "case and port are dropped")
    s = gdash_test.eq(s, gdash_tenants.normal_host("acme.example.com."), "acme.example.com", "and a trailing dot")
    s = gdash_test.eq(s, gdash_tenants.normal_host(unknown), "", "and no Host at all is the empty host")

    ' --- the registry's own shape ---
    base = root + "/tenants"
    made = gdash_paths.ensure_dir(base + "/acme")
    good = { format: 1, base: base, tenants: { acme: { hosts: ["acme.example.test"], status: "active", format: 1 } } }
    s = gdash_test.eq(s, count(gdash_tenants.validate_registry(good)), 0, "a well-formed registry validates")
    two = { format: 1, base: base, tenants: { a: { hosts: ["x.test"], status: "active" }, b: { hosts: ["x.test"], status: "active" } } }
    s = gdash_test.contains_text(s, join(gdash_tenants.validate_registry(two), "|"), "host 'x.test' is listed by both", "one host, two tenants is refused")
    odd = { format: 1, base: "relative/dir", tenants: { "Bad.Id": { hosts: ["Upper.test"], status: "maybe" } } }
    ov = join(gdash_tenants.validate_registry(odd), "|")
    s = gdash_test.contains_text(s, ov, "'base' must be an absolute directory", "a relative base is refused")
    s = gdash_test.contains_text(s, ov, "tenant id 'Bad.Id' is not a valid id", "a bad id in the file is refused")
    s = gdash_test.contains_text(s, ov, "has status 'maybe'", "an unknown status is refused")
    s = gdash_test.contains_text(s, ov, "which is not a lowercase host name", "a host written in capitals is refused, so matching cannot depend on it")

    ' --- containment: the root a tenant resolves to stays inside the base ---
    s = gdash_test.eq(s, gdash_tenants.root_of(good, "acme"), real_path(base + "/acme"), "a tenant's root is <base>/<id>, canonicalised")
    s = gdash_test.eq(s, gdash_tenants.root_of(good, "../etc"), "", "an id that is not an id resolves nowhere")
    ' A tenant directory that is a symlink out of the base is the escape the
    ' id rule cannot see. real_path can, and it is refused.
    outside = root + "/outside"
    made = gdash_paths.ensure_dir(outside)
    linked = process.run({ command: "ln", args: ["-s", outside, base + "/evil"] })
    s = gdash_test.eq(s, gdash_tenants.root_of(good, "evil"), "", "a tenant directory symlinked out of the base is refused")

    ' --- resolution: absent registry is single-tenant; present, it decides ---
    bp = gdash_paths.roles(root + "/server")
    made = gdash_paths.ensure_dir(bp.config_dir)
    none = gdash_tenants.resolve_host(bp, "anything.test")
    s = gdash_test.ok(s, none.ok and none.p.root = root + "/server", "with no registry, every host is the deployment's own root")
    rf {file} = gdash_paths.tenants_file(bp)
    write(rf, encode(good))
    r = gdash_tenants.resolve_host(bp, "ACME.example.test:80")
    s = gdash_test.ok(s, r.ok, "with one, a listed host resolves")
    s = gdash_test.eq(s, r.p.root, real_path(base + "/acme"), "to its tenant's root")
    u = gdash_tenants.resolve_host(bp, "nobody.test")
    s = gdash_test.eq(s, u.status, 404, "an unknown host is refused, never defaulted")
    s = gdash_test.eq(s, gdash_tenants.resolve_host(bp, "").status, 404, "and so is a request with no Host")
    write(rf, "{ not json")
    s = gdash_test.eq(s, gdash_tenants.resolve_host(bp, "acme.example.test").status, 503, "a registry that does not read refuses every host")

    exit(gdash_test.report(s))
end program
