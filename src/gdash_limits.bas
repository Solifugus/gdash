' gdash — limits (GDASH-16; gdash_saas_design.md §6, §7).
'
' What one root may consume, and whether it may publish to the world. Five
' limits, each the operator's and never the tenant's:
'
'   open_access       whether a dashboard here may say `access: open`
'   disk_bytes        what the root may hold on disk before a refresh is refused
'   refresh_children  how many refresh children this root may run at once
'   max_cells         the dataset-size ceiling, rows x columns, measured
'   refresh_memory    the memory a refresh child may use: "auto", from max_cells
'   model_budget      what this root may spend on models in a calendar month
'
' plus one for the whole server, `refresh_children` under "server", which caps
' every root's children together.
'
' THE LIMITS ARE FOUND FROM THE ROOT, NOT HANDED DOWN. A tenant's root carries
' its stamp (etc/tenant.json), and the stamp is what says "this root is a
' tenant, under this registry". Every entry point -- a request, the scheduler,
' an operator's CLI with a bare --root -- reaches the same answer from `p`
' alone, so none can bypass a limit by arriving another way.
'
' AND THEY FAIL CLOSED. A root that is stamped as a tenant but whose registry
' does not read, does not list it, or lists it at another directory, gets
' the most restrictive answer there is: no open access, no refresh, no model
' spend. A single root -- no stamp -- is today's gdash, and its defaults are
' the intranet's: `access: open` is the per-dashboard opt-in it always was.
'
' Where each lives: server-wide knobs and the defaults for each kind of root
' in the BASE's etc/limits.json; one tenant's own overrides in its registry
' entry, under "limits". Neither is in a tenant's own etc/, because a limit a
' tenant could edit is not one.

library gdash_limits

    load gdash_paths from "gdash_paths.bas"
    load gdash_tenants from "gdash_tenants.bas"

    function limit_names()
        return ["open_access", "disk_bytes", "refresh_children", "max_cells", "refresh_memory", "model_budget"]
    end function

    ' The measured ceiling (GDASH-16 step 0): a refresh child costs about 300
    ' bytes a cell at its peak, so a million cells is about 300 MB, and four
    ' children at once about 1.2 GB.
    function builtin(scope)
        if scope = "server" then
            return { refresh_children: 4 }
        end if
        if scope = "tenant" then
            return { open_access: false, disk_bytes: 1073741824, refresh_children: 2, max_cells: 1000000, refresh_memory: "auto",
                     model_budget: { amount: "0.00", currency: "USD" } }
        end if
        return { open_access: true, disk_bytes: "none", refresh_children: 4, max_cells: 1000000, refresh_memory: "auto", model_budget: "none" }
    end function

    ' The most restrictive answer, for a root whose limits cannot be known.
    function closed(message)
        return { ok: false, scope: "tenant", tenant: "", open_access: false, disk_bytes: 0, refresh_children: 0, max_cells: 0, refresh_memory: 1,
                 model_budget: { amount: "0.00", currency: "USD" }, server_children: 0, base: {}, message: message }
    end function

    function _whole(v, least)
        return type(v) = "number" and v = floor(v) and v >= least
    end function

    ' Sentences, one per wrong value. `where` names the place the values came
    ' from, so an operator is told which file to open.
    function validate_limits(lim, where)
        errs = []
        if type(lim) != "record" then
            return [where + " must be an object"]
        end if
        for each k in keys(lim)
            v = lim[k]
            if not contains(limit_names(), k) then
                errs = append(errs, where + " sets '" + k + "'; the limits are " + join(limit_names(), ", "))
            else if k = "open_access" then
                if type(v) != "boolean" then
                    errs = append(errs, where + " 'open_access' must be true or false")
                end if
            else if k = "disk_bytes" then
                if not (v = "none" or _whole(v, 1)) then
                    errs = append(errs, where + " 'disk_bytes' must be a whole number of bytes, at least 1, or \"none\"")
                end if
            else if k = "refresh_memory" then
                if not (v = "auto" or _whole(v, 1)) then
                    errs = append(errs, where + " 'refresh_memory' must be a whole number of bytes, at least 1, or \"auto\"")
                end if
            else if k = "refresh_children" or k = "max_cells" then
                if not _whole(v, 1) then
                    errs = append(errs, where + " '" + k + "' must be a whole number, at least 1")
                end if
            else if k = "model_budget" then
                if v != "none" then
                    m = _budget_money(v)
                    if not m.ok then
                        errs = append(errs, where + " 'model_budget' " + m.message)
                    end if
                end if
            end if
        next
        return errs
    end function

    ' { ok, amount (money), message }. A budget is { amount: "25.00",
    ' currency: "USD" }, the amount as TEXT so it is read exactly.
    function _budget_money(v)
        if type(v) != "record" then
            return { ok: false, amount: unknown, message: "must be \"none\" or { \"amount\": \"25.00\", \"currency\": \"USD\" }" }
        end if
        if type(v["amount"]) != "string" then
            return { ok: false, amount: unknown, message: "amount must be decimal text, such as \"25.00\", so it is read exactly" }
        end if
        on error goto next
        m = money.of(string(default(v["currency"], "")), v["amount"])
        if error then
            return { ok: false, amount: unknown, message: "is not an amount in a known currency: " + error.message }
        end if
        on error stop
        if m < money.of(money.currency(m), "0") then
            return { ok: false, amount: unknown, message: "must not be negative" }
        end if
        return { ok: true, amount: m, message: "" }
    end function

    ' The base's etc/limits.json. { ok, present, file, errors }. Absent is the
    ' built-in defaults; present and wrong is refused, for every root under
    ' it -- a limits file that does not read is not permission to have none.
    function load_limits_file(base_p)
        path = gdash_paths.limits_file(base_p)
        if not gdash_paths.path_exists(path) then
            return { ok: true, present: false, file: {}, errors: [] }
        end if
        on error goto next
        f {file} = path
        got = try_decode(read(f))
        if error or not got.ok then
            return { ok: false, present: true, file: {}, errors: [path + " is not valid JSON"] }
        end if
        on error stop
        lf = got.value
        if type(lf) != "record" then
            return { ok: false, present: true, file: {}, errors: [path + " must be an object"] }
        end if
        errs = []
        if type(lf["format"]) != "number" or lf["format"] != 1 then
            errs = append(errs, path + " has format '" + string(lf["format"]) + "'; this build reads format 1")
        end if
        for each k in keys(lf)
            if not contains(["format", "server", "root", "tenants"], k) then
                errs = append(errs, path + " has a section '" + k + "'; the sections are server, root and tenants")
            end if
        next
        if not is_unknown(lf["server"]) then
            if type(lf["server"]) != "record" then
                errs = append(errs, path + " 'server' must be an object")
            else
                for each k in keys(lf["server"])
                    if k != "refresh_children" then
                        errs = append(errs, path + " 'server' sets '" + k + "'; the server-wide limit is refresh_children")
                    else if not _whole(lf["server"][k], 1) then
                        errs = append(errs, path + " 'server' 'refresh_children' must be a whole number, at least 1")
                    end if
                next
            end if
        end if
        for each section in ["root", "tenants"]
            if not is_unknown(lf[section]) then
                for each e in validate_limits(lf[section], path + " '" + section + "'")
                    errs = append(errs, e)
                next
            end if
        next
        return { ok: count(errs) = 0, present: true, file: lf, errors: errs }
    end function

    function _over(base, more)
        out = base
        if type(more) = "record" then
            for each k in keys(more)
                out[k] = more[k]
            next
        end if
        return out
    end function

    function _answer(scope, tenant, lim, server_children, base_p)
        out = { ok: true, scope: scope, tenant: tenant, open_access: lim["open_access"], disk_bytes: lim["disk_bytes"],
                refresh_children: lim["refresh_children"], max_cells: lim["max_cells"], refresh_memory: lim["refresh_memory"], model_budget: lim["model_budget"],
                server_children: server_children, base: base_p, message: "" }
        return out
    end function

    ' The stamp, read without trusting it: { stamped, ok, tenant, registry }.
    function _stamp(p)
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
    function _base_of(p, stamp)
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

    ' This root's limits. { ok, scope, tenant, open_access, disk_bytes,
    ' refresh_children, max_cells, model_budget, server_children, base,
    ' message }. Never raises.
    function for_root(p)
        st = _stamp(p)
        if not st.stamped then
            lf = load_limits_file(p)
            if not lf.ok then
                return closed(join(lf.errors, "; "))
            end if
            server = _over(builtin("server"), lf.file["server"])
            lim = _over(builtin("root"), lf.file["root"])
            return _answer("root", "", lim, server["refresh_children"], p)
        end if
        if not st.ok or st.tenant = "" then
            return closed("this root's tenant stamp does not read")
        end if
        base_p = _base_of(p, st)
        loaded = gdash_tenants.load_registry(base_p)
        if not loaded.present or not loaded.ok then
            return closed("tenant '" + st.tenant + "' has no readable registry at " + gdash_paths.tenants_file(base_p))
        end if
        entry = loaded.registry["tenants"][st.tenant]
        if is_unknown(entry) then
            return closed("tenant '" + st.tenant + "' is not in the registry")
        end if
        ' The registry must place this tenant HERE. A stamped directory copied
        ' elsewhere, or a stamp edited to name another tenant, is not that
        ' tenant and does not get its limits.
        on error goto next
        here = real_path(p.root)
        if error then
        end if
        on error stop
        if type(here) != "string" or gdash_tenants.root_of(loaded.registry, st.tenant) != here then
            return closed("this root is stamped as tenant '" + st.tenant + "', and the registry places that tenant elsewhere")
        end if
        lf = load_limits_file(base_p)
        if not lf.ok then
            return closed(join(lf.errors, "; "))
        end if
        own = default(entry["limits"], {})
        errs = validate_limits(own, "tenant '" + st.tenant + "' limits")
        if count(errs) > 0 then
            return closed(join(errs, "; "))
        end if
        server = _over(builtin("server"), lf.file["server"])
        lim = _over(_over(builtin("tenant"), lf.file["tenants"]), own)
        return _answer("tenant", st.tenant, lim, server["refresh_children"], base_p)
    end function

    ' Setting one tenant's limit: validated, then the whole registry written
    ' as every registry change is. `value` is text from the command line,
    ' read as the limit's own kind: "true", "1073741824", "none", "25.00USD".
    function parse_value(nm, text)
        t = trim(string(text))
        if nm = "open_access" then
            if t = "true" or t = "false" then
                return { ok: true, value: t = "true", message: "" }
            end if
            return { ok: false, value: unknown, message: "open_access is true or false" }
        end if
        if nm = "model_budget" then
            if t = "none" then
                return { ok: true, value: "none", message: "" }
            end if
            if len(t) > 3 then
                code = mid(t, len(t) - 3, 3)
                amt = mid(t, 0, len(t) - 3)
                if upper(code) = code and contains("0123456789", mid(amt, len(amt) - 1, 1)) then
                    return { ok: true, value: { amount: amt, currency: code }, message: "" }
                end if
            end if
            return { ok: false, value: unknown, message: "model_budget is \"none\" or an amount and its currency, such as 25.00USD" }
        end if
        if nm = "refresh_memory" and t = "auto" then
            return { ok: true, value: "auto", message: "" }
        end if
        if nm = "disk_bytes" and t = "none" then
            return { ok: true, value: "none", message: "" }
        end if
        on error goto next
        n = number(t)
        if error then
            return { ok: false, value: unknown, message: nm + " must be a whole number" }
        end if
        on error stop
        return { ok: true, value: n, message: "" }
    end function

    function set_tenant_limit(base_p, id, nm, text)
        if not contains(limit_names(), nm) then
            return { ok: false, message: "'" + string(nm) + "' is not a limit; the limits are " + join(limit_names(), ", ") }
        end if
        got = parse_value(nm, text)
        if not got.ok then
            return { ok: false, message: got.message }
        end if
        loaded = gdash_tenants.load_registry(base_p)
        if not loaded.present or not loaded.ok then
            return { ok: false, message: "there is no readable tenant registry" }
        end if
        reg = loaded.registry
        if is_unknown(reg["tenants"][id]) then
            return { ok: false, message: "no tenant '" + string(id) + "'" }
        end if
        own = default(reg["tenants"][id]["limits"], {})
        own[nm] = got.value
        errs = validate_limits(own, "tenant '" + id + "' limits")
        if count(errs) > 0 then
            return { ok: false, message: join(errs, "; ") }
        end if
        reg["tenants"][id]["limits"] = own
        return gdash_tenants.write_registry(base_p, reg)
    end function

    ' A limit as a person reads it, for `tenant limits` and refusals.
    function shown(nm, v)
        if nm = "model_budget" then
            if v = "none" then
                return "none"
            end if
            return string(v["amount"]) + " " + string(v["currency"]) + " a month"
        end if
        if nm = "refresh_memory" and v != "auto" then
            return bytes_text(v)
        end if
        if nm = "disk_bytes" then
            if v = "none" then
                return "none"
            end if
            return bytes_text(v)
        end if
        return string(v)
    end function

    ' The memory limit a refresh child runs under (gbasic B1). "auto" is
    ' the interpreter's baseline with room to spare, plus TWICE the measured
    ' 300 bytes a cell at max_cells: generous enough that a dataset at the
    ' ceiling never meets it, tight enough that a result far above the
    ' ceiling dies in its own process rather than in the server's cgroup.
    function child_memory(lim)
        if lim.refresh_memory = "auto" then
            return 134217728 + lim.max_cells * 600
        end if
        return lim.refresh_memory
    end function

    function bytes_text(n)
        if n >= 1073741824 then
            return string(round(n / 1073741824, 2)) + " GiB"
        end if
        if n >= 1048576 then
            return string(round(n / 1048576, 1)) + " MiB"
        end if
        if n >= 1024 then
            return string(round(n / 1024, 1)) + " KiB"
        end if
        return string(n) + " bytes"
    end function

    ' --- disk -----------------------------------------------------------------
    '
    ' What a root holds on disk: its state, cache and log roles. Not run/,
    ' which is tmpfs and disposable. Measured, not estimated -- a G-SQL
    ' database's directory runs ahead of its live data between compactions
    ' (GDASH-16 ask B3), and the quota is about the volume, so it counts what
    ' the volume holds.
    function _du(dir)
        total = 0
        on error goto next
        entries = list(dir)
        if error then
            return 0
        end if
        on error stop
        for each e in entries
            if e.type = "folder" then
                total += _du(e.path)
            else
                total += default(e.size, 0)
            end if
        next
        return total
    end function

    function disk_used(p)
        return _du(p.state_dir) + _du(p.cache_dir) + _du(p.log_dir)
    end function

    ' { ok, used, message }: ok when the root is within its quota.
    function disk_check(p, lim)
        if lim.disk_bytes = "none" then
            return { ok: true, used: 0, message: "" }
        end if
        used = disk_used(p)
        if used > lim.disk_bytes then
            return { ok: false, used: used, message: "this site is over its disk quota (" + bytes_text(used) + " of " + bytes_text(lim.disk_bytes) + "); the refresh was refused and the previous data is still served" }
        end if
        return { ok: true, used: used, message: "" }
    end function

    ' --- refresh slots --------------------------------------------------------
    '
    ' A slot is a lock file taken WITHOUT WAITING. A refresh takes one slot
    ' from the server's set and one from its root's, or is deferred: a
    ' scheduler steps around a full server rather than queueing behind it,
    ' and the next pass tries again. A slot goes when its holder dies, because
    ' it is a lock, so a crashed child never leaks one.
    '
    ' { ok, deferred, held: [files], message }
    function take_slots(p, lim)
        held = []
        if lim.refresh_children < 1 or lim.server_children < 1 then
            return { ok: false, deferred: false, held: [], message: "refreshes are not permitted here: " + default(lim.message, "") }
        end if
        g = _take(lim.base, "server", lim.server_children)
        if type(g) = "string" then
            return { ok: false, deferred: false, held: [], message: g }
        end if
        if is_unknown(g) then
            return { ok: false, deferred: true, held: [], message: "deferred: the server is already running " + string(lim.server_children) + " refreshes, its limit" }
        end if
        held = append(held, g)
        scope = "root"
        if lim.scope = "tenant" then
            scope = "tenant"
        end if
        t = _take(p, scope, lim.refresh_children)
        if type(t) = "string" then
            released = release_slots(held)
            return { ok: false, deferred: false, held: [], message: t }
        end if
        if is_unknown(t) then
            released = release_slots(held)
            return { ok: false, deferred: true, held: [], message: "deferred: this site is already running " + string(lim.refresh_children) + " refreshes, its limit" }
        end if
        held = append(held, t)
        return { ok: true, deferred: false, held: held, message: "" }
    end function

    ' The slot's file when one was free; unknown when all are held; a string
    ' saying why when slots cannot be taken at all.
    function _take(p, scope, n)
        made = gdash_paths.ensure_dir(gdash_paths.dir_of(gdash_paths.slot_file(p, scope, 0)))
        i = 0
        while i < n
            path = gdash_paths.slot_file(p, scope, i)
            on error goto next
            f {file} = path
            if not exists(f) then
                write(f, "")
            end if
            got = lock(f, { wait: false })
            ' A RAISE is not "held by someone else": it is an interpreter
            ' without the non-blocking lock, and saying "the server is full"
            ' then would send an operator looking for refreshes that do not
            ' exist.
            if error then
                return "refreshes cannot be limited by this gBASIC: it has no lock(f, { wait: false }) (0.11.0 or later is required): " + error.message
            end if
            on error stop
            if got then
                return f
            end if
            i += 1
        end while
        return unknown
    end function

    function release_slots(held)
        for each f in held
            on error goto next
            unlock(f)
            if error then
            end if
            on error stop
        next
        return true
    end function

end library
