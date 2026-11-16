' gdash — tenants (GDASH-15; gdash_saas_design.md).
'
' A TENANT IS A ROOT: one directory holding the five roles the resolver
' already mints, sharing nothing with any other tenant. The wall between
' tenants is the filesystem, not the code. This module decides, once per
' request and at the edge, WHICH root a request belongs to; everything
' downstream already takes `p` and needs no change.
'
' THREE RULES, AND THEY ARE THE WHOLE SECURITY ARGUMENT (design §2):
'   1. an unknown host is refused -- never a default tenant, never the first
'      one, never the single-tenant root;
'   2. resolution happens once and yields `p`; nothing downstream re-derives
'      a tenant from a cookie, a path, a form field or a record;
'   3. a suspended tenant is refused at resolution, not hidden in the UI.
'
' SINGLE-TENANT IS THE ABSENCE OF A REGISTRY: no `tenants.json` means today's
' gdash, resolving GDASH_ROOT or the FHS paths exactly as before.
'
' A tenant's root is DERIVED -- `<base>/<id>` -- rather than written in the
' registry. A free-form root would be a path an edit could point anywhere; a
' derived one, checked with real_path against the base on a separator
' boundary, cannot leave it.

library gdash_tenants

    load gdash_paths from "gdash_paths.bas"

    ' `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$`: no dots, no slashes, no case.
    ' Stricter than a dashboard name on purpose -- here the interpolated
    ' segment IS the tenant.
    function valid_id(id)
        s = string(id)
        n = len(s)
        if n < 1 or n > 40 then
            return false
        end if
        i = 0
        while i < n
            ch = mid(s, i, 1)
            edge = i = 0 or i = n - 1
            if not contains("abcdefghijklmnopqrstuvwxyz0123456789", ch) then
                if ch != "-" or edge then
                    return false
                end if
            end if
            i += 1
        end while
        return true
    end function

    ' A host as a registry lists it: lowercase, with no port and no trailing
    ' dot. "ACME.example.com:443" and "acme.example.com." are the same site.
    function normal_host(h)
        s = lower(trim(string(default(h, ""))))
        colon = find(s, ":")
        if not is_nothing(colon) and not is_unknown(colon) then
            s = mid(s, 0, colon)
        end if
        while ends_with(s, ".")
            s = mid(s, 0, len(s) - 1)
        end while
        return s
    end function

    function _valid_host(h)
        if h = "" or len(h) > 253 then
            return false
        end if
        i = 0
        while i < len(h)
            if not contains("abcdefghijklmnopqrstuvwxyz0123456789.-", mid(h, i, 1)) then
                return false
            end if
            i += 1
        end while
        return true
    end function

    ' { present, ok, registry, errors }. Absent is not an error: it is the
    ' single-tenant deployment. Present and wrong is an error, and every
    ' request is then refused -- a registry that does not read is not a
    ' reason to serve something.
    function load_registry(base_p)
        path = gdash_paths.tenants_file(base_p)
        if not gdash_paths.path_exists(path) then
            return { present: false, ok: true, registry: {}, errors: [] }
        end if
        on error goto next
        f {file} = path
        got = try_decode(read(f))
        if error or not got.ok then
            return { present: true, ok: false, registry: {}, errors: ["the tenant registry " + path + " is not valid JSON"] }
        end if
        on error stop
        errs = validate_registry(got.value)
        return { present: true, ok: count(errs) = 0, registry: got.value, errors: errs }
    end function

    function validate_registry(reg)
        errs = []
        if type(reg) != "record" then
            return ["the tenant registry is not an object"]
        end if
        if type(reg["format"]) != "number" or reg["format"] != 1 then
            errs = append(errs, "the tenant registry has format '" + string(reg["format"]) + "'; this build reads format 1")
        end if
        base = string(default(reg["base"], ""))
        if not starts_with(base, "/") then
            errs = append(errs, "the tenant registry's 'base' must be an absolute directory")
        end if
        if type(reg["tenants"]) != "record" then
            return append(errs, "the tenant registry has no 'tenants' object")
        end if
        seen = {}
        for each id in keys(reg["tenants"])
            t = reg["tenants"][id]
            if not valid_id(id) then
                errs = append(errs, "tenant id '" + id + "' is not a valid id (lowercase letters, digits and inner hyphens, at most 40)")
            end if
            if type(t) != "record" then
                errs = append(errs, "tenant '" + id + "' must be an object")
            else
                if not contains(["active", "suspended"], string(default(t["status"], ""))) then
                    errs = append(errs, "tenant '" + id + "' has status '" + string(t["status"]) + "'; the statuses are active and suspended")
                end if
                if type(t["hosts"]) != "array" or count(t["hosts"]) = 0 then
                    errs = append(errs, "tenant '" + id + "' names no hosts")
                else
                    for each h in t["hosts"]
                        nh = normal_host(h)
                        if nh != string(h) or not _valid_host(nh) then
                            errs = append(errs, "tenant '" + id + "' lists host '" + string(h) + "', which is not a lowercase host name")
                        else if not is_unknown(seen[nh]) then
                            ' One host, two tenants is exactly the ambiguity
                            ' rule 1 exists to refuse.
                            errs = append(errs, "host '" + nh + "' is listed by both '" + seen[nh] + "' and '" + id + "'")
                        else
                            seen[nh] = id
                        end if
                    next
                end if
            end if
        next
        return errs
    end function

    ' The root a tenant id lives at, contained in the base on a separator
    ' boundary. "" when it would escape, which the id rule makes impossible
    ' and this checks anyway: the containment is what is relied on, not the
    ' regex.
    function root_of(reg, id)
        base = string(reg["base"])
        while ends_with(base, "/") and len(base) > 1
            base = mid(base, 0, len(base) - 1)
        end while
        if not valid_id(id) then
            return ""
        end if
        root = base + "/" + id
        on error goto next
        rb = real_path(base)
        rr = real_path(root)
        if error then
        end if
        on error stop
        ' A root not yet created has no canonical path; its parent is the
        ' base and the id cannot hold a separator, so the derived path is the
        ' answer until it exists. Once it exists, it must canonicalise INSIDE
        ' the canonical base -- a symlinked tenant directory pointing out of
        ' the base is refused here.
        if type(rr) != "string" then
            return root
        end if
        if type(rb) != "string" or not starts_with(rr, rb + "/") then
            return ""
        end if
        return rr
    end function

    ' Which root a request belongs to. { ok, p, tenant, status, message }:
    ' status is the HTTP status to refuse with when not ok.
    function resolve_host(base_p, host)
        loaded = load_registry(base_p)
        if not loaded.present then
            return { ok: true, p: base_p, tenant: "", status: 200, message: "" }
        end if
        if not loaded.ok then
            return { ok: false, p: {}, tenant: "", status: 503, message: "this server's tenant registry is invalid" }
        end if
        h = normal_host(host)
        reg = loaded.registry
        for each id in keys(reg["tenants"])
            t = reg["tenants"][id]
            if contains(t["hosts"], h) then
                if string(t["status"]) != "active" then
                    return { ok: false, p: {}, tenant: id, status: 403, message: "this site is suspended" }
                end if
                root = root_of(reg, id)
                if root = "" then
                    return { ok: false, p: {}, tenant: id, status: 503, message: "this site's directory is not where it should be" }
                end if
                return { ok: true, p: gdash_paths.roles(root), tenant: id, status: 200, message: "" }
            end if
        next
        return { ok: false, p: {}, tenant: "", status: 404, message: "no such site" }
    end function

    ' A tenant's roots by id, for the CLI and the scheduler, which are run by
    ' an operator and so are not refused for a suspended tenant.
    function roles_for(base_p, id)
        loaded = load_registry(base_p)
        if not loaded.present then
            return { ok: false, p: {}, message: "there is no tenant registry (" + gdash_paths.tenants_file(base_p) + ")" }
        end if
        if not loaded.ok then
            return { ok: false, p: {}, message: join(loaded.errors, "; ") }
        end if
        if is_unknown(loaded.registry["tenants"][id]) then
            return { ok: false, p: {}, message: "no tenant '" + string(id) + "'" }
        end if
        root = root_of(loaded.registry, id)
        if root = "" then
            return { ok: false, p: {}, message: "tenant '" + string(id) + "' resolves outside the base" }
        end if
        return { ok: true, p: gdash_paths.roles(root), message: "" }
    end function

    ' --- changing the registry --------------------------------------------------
    '
    ' Every change is a whole new registry, validated, written to a temporary
    ' file and renamed over the old one: a reader never sees half of it.
    function _write(base_p, reg)
        errs = validate_registry(reg)
        if count(errs) > 0 then
            return { ok: false, message: join(errs, "; ") }
        end if
        path = gdash_paths.tenants_file(base_p)
        made = gdash_paths.ensure_dir(base_p.config_dir)
        on error goto next
        tf {file} = path + ".tmp"
        write(tf, encode(reg))
        atomic_replace(path + ".tmp", path)
        if error then
            return { ok: false, message: "cannot write " + path }
        end if
        restricted = gdash_paths.restrict(path)
        return { ok: true, message: "" }
    end function

    ' Public for gdash_limits, which changes a tenant's limits the same way.
    function write_registry(base_p, reg)
        return _write(base_p, reg)
    end function

    ' The registry's canonical path, for a tenant's stamp.
    function _registry_path(base_p)
        path = gdash_paths.tenants_file(base_p)
        on error goto next
        rp = real_path(base_p.config_dir)
        if error then
        end if
        on error stop
        if type(rp) = "string" then
            return rp + "/tenants.json"
        end if
        return path
    end function

    function _current(base_p, base)
        loaded = load_registry(base_p)
        if loaded.present and not loaded.ok then
            return { ok: false, registry: {}, message: join(loaded.errors, "; ") }
        end if
        if not loaded.present then
            ' No --base: tenants go where precious state goes (G17-1).
            chosen = string(base)
            if chosen = "" then
                chosen = gdash_paths.tenants_base(base_p)
            end if
            made = gdash_paths.ensure_dir(chosen)
            on error goto next
            abs = real_path(chosen)
            if error then
                return { ok: false, registry: {}, message: "cannot create the tenant base " + chosen }
            end if
            on error stop
            return { ok: true, registry: { format: 1, base: abs, tenants: {} }, message: "" }
        end if
        return { ok: true, registry: loaded.registry, message: "" }
    end function

    ' Creating a tenant: its five role directories and a format stamp, THEN
    ' the registry entry. The entry is what makes a tenant resolvable, so a
    ' tenant half-created is unreachable rather than half-open -- the shape
    ' publish uses: write the snapshot, then move the pointer.
    function create_tenant(base_p, id, hosts, base)
        cur = _current(base_p, base)
        if not cur.ok then
            return { ok: false, root: "", message: cur.message }
        end if
        reg = cur.registry
        if not valid_id(id) then
            return { ok: false, root: "", message: "'" + string(id) + "' is not a valid tenant id (lowercase letters, digits and inner hyphens, at most 40)" }
        end if
        if not is_unknown(reg["tenants"][id]) then
            return { ok: false, root: "", message: "tenant '" + id + "' already exists" }
        end if
        norm = []
        for each h in hosts
            norm = append(norm, normal_host(h))
        next
        if count(norm) = 0 then
            return { ok: false, root: "", message: "a tenant needs at least one --host" }
        end if
        made = gdash_paths.ensure_dir(string(reg["base"]))
        root = root_of(reg, id)
        if root = "" then
            return { ok: false, root: "", message: "tenant '" + id + "' would resolve outside " + string(reg["base"]) }
        end if
        tp = gdash_paths.roles(root)
        for each d in [tp.config_dir, tp.state_dir, tp.cache_dir, tp.log_dir, tp.run_dir, gdash_paths.dashboards_dir(tp)]
            if not gdash_paths.ensure_dir(d) then
                return { ok: false, root: root, message: "cannot create " + d }
            end if
        next
        ' 0700: what a tenant holds is another organisation's, and no other
        ' local user has any business listing it.
        for each d in [root, tp.config_dir, tp.state_dir, tp.cache_dir, tp.log_dir, tp.run_dir]
            if not gdash_paths.close_dir(d) then
                return { ok: false, root: root, message: "cannot restrict " + d + " to its owner" }
            end if
        next
        st = write_stamp(base_p, tp, id, 1)
        if not st.ok then
            return { ok: false, root: root, message: st.message }
        end if
        reg["tenants"][id] = { hosts: norm, status: "active", format: 1 }
        w = _write(base_p, reg)
        if not w.ok then
            return { ok: false, root: root, message: w.message }
        end if
        return { ok: true, root: root, message: "" }
    end function

    ' A format stamp per tenant, so a later migration knows what it is
    ' looking at. One root never needed this; hundreds will. It names the
    ' registry, so a root reached by a bare --root still finds the limits that
    ' govern it (GDASH-16) -- which is why an imported tenant's stamp is
    ' rewritten for the server it now lives on.
    function write_stamp(base_p, tp, id, format)
        on error goto next
        sf {file} = gdash_paths.tenant_stamp(tp)
        write(sf, encode({ format: format, tenant: id, registry: _registry_path(base_p) }))
        if error then
            return { ok: false, message: "cannot write the tenant's format stamp " + gdash_paths.tenant_stamp(tp) }
        end if
        return { ok: true, message: "" }
    end function

    ' The stamp, read without trusting it: { stamped, ok, tenant, registry }.
    function read_stamp(p)
        path = gdash_paths.tenant_stamp(p)
        if not gdash_paths.path_exists(path) then
            return { stamped: false, ok: true, tenant: "", registry: "" }
        end if
        on error goto next
        f {file} = path
        got = try_decode(read(f))
        if error or not got.ok or type(got.value) != "record" then
            return { stamped: true, ok: false, tenant: "", registry: "" }
        end if
        on error stop
        return { stamped: true, ok: true, tenant: string(default(got.value["tenant"], "")), registry: string(default(got.value["registry"], "")) }
    end function

    ' The base roles a stamped root answers to. A stamp written since
    ' GDASH-16 names its registry; one written before names none, and its
    ' base is then the root's parent, which is where `<base>/<id>` put it.
    function base_of(p, stamp)
        if stamp.registry != "" then
            ' Under FHS the registry is /etc/gdash/tenants.json, which is no
            ' `<root>/etc/` -- the installed roles are the base.
            fhs = gdash_paths.roles("")
            if stamp.registry = gdash_paths.tenants_file(fhs) then
                return fhs
            end if
            return gdash_paths.roles(gdash_paths.dir_of(gdash_paths.dir_of(stamp.registry)))
        end if
        return gdash_paths.roles(gdash_paths.dir_of(p.root))
    end function

    ' Whether `id` could join the registry with `entry`, before anything is
    ' written: a valid id, not taken, hosts nobody else has, a root inside
    ' the base. { ok, root, message }.
    function can_register(base_p, id, entry)
        cur = _current(base_p, "")
        if not cur.ok then
            return { ok: false, root: "", message: cur.message }
        end if
        reg = cur.registry
        if not valid_id(id) then
            return { ok: false, root: "", message: "'" + string(id) + "' is not a valid tenant id (lowercase letters, digits and inner hyphens, at most 40)" }
        end if
        if not is_unknown(reg["tenants"][id]) then
            return { ok: false, root: "", message: "tenant '" + id + "' already exists here; import --as another id" }
        end if
        reg["tenants"][id] = entry
        errs = validate_registry(reg)
        if count(errs) > 0 then
            return { ok: false, root: "", message: join(errs, "; ") }
        end if
        made = gdash_paths.ensure_dir(string(reg["base"]))
        root = root_of(reg, id)
        if root = "" then
            return { ok: false, root: "", message: "tenant '" + id + "' would resolve outside " + string(reg["base"]) }
        end if
        return { ok: true, root: root, message: "" }
    end function

    ' The entry, written: what makes a tenant resolvable, so always last.
    function register(base_p, id, entry)
        cur = _current(base_p, "")
        if not cur.ok then
            return { ok: false, message: cur.message }
        end if
        reg = cur.registry
        if not is_unknown(reg["tenants"][id]) then
            return { ok: false, message: "tenant '" + id + "' already exists" }
        end if
        reg["tenants"][id] = entry
        return _write(base_p, reg)
    end function

    function set_tenant_status(base_p, id, status)
        cur = _current(base_p, "")
        if not cur.ok then
            return { ok: false, message: cur.message }
        end if
        reg = cur.registry
        if is_unknown(reg["tenants"][id]) then
            return { ok: false, message: "no tenant '" + string(id) + "'" }
        end if
        reg["tenants"][id]["status"] = status
        return _write(base_p, reg)
    end function

    ' Deleting a tenant removes its registry entry, which makes it
    ' unreachable at once. Its directory is left in place unless the caller
    ' asks for it to go too: an entry is easy to recreate, a tenant's data is
    ' not, and the order -- unreachable first -- is the same either way.
    function remove_tenant(base_p, id)
        cur = _current(base_p, "")
        if not cur.ok then
            return { ok: false, root: "", message: cur.message }
        end if
        reg = cur.registry
        if is_unknown(reg["tenants"][id]) then
            return { ok: false, root: "", message: "no tenant '" + string(id) + "'" }
        end if
        root = root_of(reg, id)
        kept = {}
        for each k in keys(reg["tenants"])
            if k != id then
                kept[k] = reg["tenants"][k]
            end if
        next
        reg["tenants"] = kept
        w = _write(base_p, reg)
        return { ok: w.ok, root: root, message: w.message }
    end function

    ' --- migration (GDASH-17) ---------------------------------------------------
    '
    ' Every upgrade must migrate every tenant, and with hundreds an operator
    ' cannot open each one. The stamp says what each root is.
    function current_format()
        return 1
    end function

    ' One step from `from` to `from + 1`, given the tenant's roles. There are
    ' none: format 1 is the only one there has been. A format 2 adds its step
    ' here, and `migrate` already walks a tenant through every step between.
    function _step(from, tp)
        return { ok: false, message: "no step is known from format " + string(from) }
    end function

    ' [{ id, from, to, status, message }], status one of current, migrated,
    ' newer (this build is older than the tenant), unreadable, failed.
    function migrate(base_p, ids)
        out = []
        loaded = load_registry(base_p)
        if not loaded.present or not loaded.ok then
            return out
        end if
        for each id in ids
            row = { id: id, from: unknown, to: current_format(), status: "unreadable", message: "" }
            tr = roles_for(base_p, id)
            if not tr.ok then
                row.message = tr.message
            else
                st = read_stamp(tr.p)
                f = unknown
                if st.stamped and st.ok then
                    got = try_decode(read({file}gdash_paths.tenant_stamp(tr.p)))
                    if got.ok and type(got.value["format"]) = "number" then
                        f = got.value["format"]
                    end if
                end if
                row.from = f
                if is_unknown(f) then
                    row.message = "its stamp " + gdash_paths.tenant_stamp(tr.p) + " does not say a format"
                else if f > current_format() then
                    row.status = "newer"
                    row.message = "format " + string(f) + " is newer than this build's " + string(current_format()) + "; this tenant needs a newer gdash"
                else if f = current_format() then
                    row.status = "current"
                else
                    at = f
                    ok = true
                    while at < current_format() and ok
                        stp = _step(at, tr.p)
                        if stp.ok then
                            at += 1
                        else
                            ok = false
                            row.status = "failed"
                            row.message = stp.message
                        end if
                    end while
                    if ok then
                        w = write_stamp(base_p, tr.p, id, current_format())
                        row.status = "migrated"
                        if not w.ok then
                            row.status = "failed"
                            row.message = w.message
                        end if
                    end if
                end if
            end if
            out = append(out, row)
        next
        return out
    end function

    function tenant_list(base_p)
        loaded = load_registry(base_p)
        if not loaded.present or not loaded.ok then
            return []
        end if
        out = []
        for each id in sort(keys(loaded.registry["tenants"]))
            t = loaded.registry["tenants"][id]
            out = append(out, { id: id, status: string(t["status"]), hosts: t["hosts"], root: root_of(loaded.registry, id) })
        next
        return out
    end function

end library
