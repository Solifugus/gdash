' gdash — dashboard record: load, shape check, validation.
'
' A dashboard validates COMPLETELY before any source database is contacted
' (design §1, load-time red/green). This phase implements the subset the spine
' needs; GDASH-1 owns the full catalog and its golden refusal messages.
'
' One limit is structural, not an omission: `sqlite.columns` has not shipped
' (finding F4), so encoding-channel names cannot be checked against a real
' result set here. Design §2 already provides for that -- channel checks
' happen at first refresh -- and gdash_store enforces them there.

library gdash_record

    load gdash_sql from "gdash_sql.bas"
    load gdash_format from "gdash_format.bas"

    function _get(r, k)
        return r[k]
    end function

    function _has(r, k)
        return not is_unknown(r[k])
    end function

    ' Read + try_decode + shape check (design §6: all JSON stores validate on
    ' read). Returns { ok, record, errors }.
    function load_file(path)
        on error goto next
        f {file} = path
        if error then
            return { ok: false, record: {}, errors: ["record file unreadable: " + path], warnings: [] }
        end if
        if not exists(f) then
            return { ok: false, record: {}, errors: ["record file not found: " + path], warnings: [] }
        end if
        text = read(f)
        if error then
            return { ok: false, record: {}, errors: ["record file unreadable: " + path], warnings: [] }
        end if
        ' try_decode reports failure as a VALUE: { ok, value, message,
        ' offset, line, column }. The decoded record is .value, and the
        ' message carries the parse position, which is worth surfacing --
        ' a hand-edited record is the normal authoring path (design §1).
        parsed = try_decode(text)
        if not parsed.ok then
            return { ok: false, record: {}, errors: ["record is not valid JSON: " + path + " (" + string(parsed.message) + " at line " + string(parsed.line) + ", column " + string(parsed.column) + ")"], warnings: [] }
        end if
        doc = parsed.value
        if type(doc) != "record" then
            return { ok: false, record: {}, errors: ["record must be a JSON object: " + path], warnings: [] }
        end if
        got = check(doc)
        return { ok: count(got.errors) = 0, record: doc, errors: got.errors, warnings: got.warnings }
    end function

    function legal_space(v)
        return contains(["between", "around", "evenly", "start", "end", "center"], v)
    end function

    ' `space` governs LEFTOVER room. When every child is weighted there is no
    ' leftover room, so the setting does nothing -- design §2 calls for a
    ' warning rather than a refusal, because the record is still renderable
    ' and the author has only asked for something that cannot happen.
    function _dead_space(node, kids, where, warnings)
        sp = node["space"]
        if is_unknown(sp) then
            return warnings
        end if
        if count(kids) = 0 then
            return warnings
        end if
        all_weighted = true
        i = 0
        while i < count(kids)
            if is_unknown(kids[i]["weight"]) then
                all_weighted = false
            end if
            i += 1
        end while
        if all_weighted then
            return concat(warnings, [where + ": 'space' is ignored because every child is weighted, so there is no leftover room to distribute"])
        end if
        return warnings
    end function

    function _validate_layout(node, vis, ctl, errors, where)
        if is_unknown(node) or type(node) != "record" then
            return concat(errors, [where + ": layout node must be an object"])
        end if
        ' `weight` is a property of a CHILD, so it is checked on every node
        ' rather than only on containers -- a weighted leaf is the common case.
        wt = node["weight"]
        if not is_unknown(wt) then
            if type(wt) != "number" or wt <= 0 then
                errors = concat(errors, [where + ": 'weight' must be a positive number"])
            end if
        end if
        if _has(node, "vert") or _has(node, "horiz") then
            kids = node["vert"]
            label = "vert"
            if is_unknown(kids) then
                kids = node["horiz"]
                label = "horiz"
            end if
            if type(kids) != "array" then
                return concat(errors, [where + "." + label + " must be an array"])
            end if
            sp = node["space"]
            if not is_unknown(sp) then
                if not legal_space(sp) then
                    errors = concat(errors, [where + ": 'space' is '" + string(sp) + "'; it must be between, around, evenly, start, end or center"])
                end if
            end if
            gp = node["gap"]
            if not is_unknown(gp) then
                if type(gp) != "number" or gp < 0 then
                    errors = concat(errors, [where + ": 'gap' must be a non-negative number"])
                end if
            end if
            i = 0
            while i < count(kids)
                errors = _validate_layout(kids[i], vis, ctl, errors, where + "." + label + "[" + string(i) + "]")
                i += 1
            end while
            return errors
        end if
        if _has(node, "visual") then
            nm = node["visual"]
            if not contains(vis, nm) then
                errors = concat(errors, [where + ": layout leaf names undefined visual '" + string(nm) + "'"])
            end if
            return errors
        end if
        if _has(node, "control") then
            nm = node["control"]
            if not contains(ctl, nm) then
                errors = concat(errors, [where + ": layout leaf names undefined control '" + string(nm) + "'"])
            end if
            return errors
        end if
        return concat(errors, [where + ": layout node must be vert, horiz, visual or control"])
    end function

    function validate(rec)
        return check(rec).errors
    end function

    function warnings_for(rec)
        return check(rec).warnings
    end function

    function _walk_warnings(node, where, warnings)
        if is_unknown(node) or type(node) != "record" then
            return warnings
        end if
        kids = node["vert"]
        label = "vert"
        if is_unknown(kids) then
            kids = node["horiz"]
            label = "horiz"
        end if
        if is_unknown(kids) or type(kids) != "array" then
            return warnings
        end if
        warnings = _dead_space(node, kids, where, warnings)
        i = 0
        while i < count(kids)
            warnings = _walk_warnings(kids[i], where + "." + label + "[" + string(i) + "]", warnings)
            i += 1
        end while
        return warnings
    end function

    function check(rec)
        errors = []
        warnings = []

        if not _has(rec, "format") then
            errors = concat(errors, ["record has no 'format'"])
        else if rec["format"] != 1 then
            errors = concat(errors, ["unsupported record format: " + string(rec["format"]) + " (this build reads format 1)"])
        end if

        if not _has(rec, "name") then
            errors = concat(errors, ["record has no 'name'"])
        end if

        ' access is a per-dashboard opt-in and everything fails closed
        ' (design §8). A record with no 'access' key is refused by the server;
        ' validation only insists the value be one it understands.
        if _has(rec, "access") then
            if rec["access"] != "open" then
                errors = concat(errors, ["unsupported access mode: '" + string(rec["access"]) + "' (this build understands 'open')"])
            end if
        end if

        params = rec["params"]
        if is_unknown(params) then
            params = {}
        end if
        param_names = keys(params)

        ' --- datasets ---
        datasets = rec["datasets"]
        if is_unknown(datasets) or type(datasets) != "record" then
            errors = concat(errors, ["record has no 'datasets' object"])
            datasets = {}
        end if
        ds_names = keys(datasets)
        i = 0
        while i < count(ds_names)
            dn = ds_names[i]
            ds = datasets[dn]
            ' A dataset becomes a table, so its name must be a legal SQL
            ' identifier (design §2).
            if not gdash_sql.legal_identifier(dn) then
                errors = concat(errors, ["dataset name is not a legal SQL identifier: '" + dn + "'"])
            end if
            if not _has(ds, "sql") then
                errors = concat(errors, ["dataset '" + dn + "' has no 'sql'"])
            else
                ' Params may appear ONLY in visual queries. A param in a
                ' dataset query would make a slicer change re-fetch from the
                ' source, silently reintroducing pass-through cost (design §2).
                found = gdash_sql.bindings(ds["sql"])
                j = 0
                while j < count(found)
                    errors = concat(errors, ["dataset '" + dn + "' binds param ':" + found[j] + "'; params may appear only in visual queries"])
                    j += 1
                end while
            end if
            if not _has(ds, "profile") then
                errors = concat(errors, ["dataset '" + dn + "' has no 'profile'"])
            end if
            if _has(ds, "refresh") then
                if ds["refresh"] != "manual" then
                    errors = concat(errors, ["dataset '" + dn + "' uses refresh policy '" + string(ds["refresh"]) + "'; this build implements 'manual' only"])
                end if
            end if
            ' money columns must declare a non-negative integer scale
            cols = ds["columns"]
            if not is_unknown(cols) then
                cn = keys(cols)
                k = 0
                while k < count(cn)
                    col = cols[cn[k]]
                    if col["type"] = "money" then
                        sc = col["scale"]
                        if is_unknown(sc) then
                            errors = concat(errors, ["money column '" + dn + "." + cn[k] + "' has no 'scale'"])
                        else if sc < 0 or sc != round(sc, 0) then
                            errors = concat(errors, ["money column '" + dn + "." + cn[k] + "' has a non-integer or negative scale"])
                        end if
                        cur = col["currency"]
                        if not is_unknown(cur) then
                            if not contains(gdash_format.supported_currencies(), cur) then
                                errors = concat(errors, ["money column '" + dn + "." + cn[k] + "' names currency '" + string(cur) + "', which this build does not support"])
                            end if
                        end if
                    end if
                    k += 1
                end while
            end if
            i += 1
        end while

        ' --- visuals ---
        visuals = rec["visuals"]
        if is_unknown(visuals) or type(visuals) != "record" then
            errors = concat(errors, ["record has no 'visuals' object"])
            visuals = {}
        end if
        vis_names = keys(visuals)
        i = 0
        while i < count(vis_names)
            vn = vis_names[i]
            v = visuals[vn]
            if not _has(v, "dataset") then
                errors = concat(errors, ["visual '" + vn + "' has no 'dataset'"])
            else if not contains(ds_names, v["dataset"]) then
                errors = concat(errors, ["visual '" + vn + "' names undefined dataset '" + string(v["dataset"]) + "'"])
            end if
            if not _has(v, "sql") then
                errors = concat(errors, ["visual '" + vn + "' has no 'sql'"])
            else
                ' Every binding resolves, before any database is touched.
                found = gdash_sql.bindings(v["sql"])
                j = 0
                while j < count(found)
                    if not contains(param_names, found[j]) then
                        errors = concat(errors, ["visual '" + vn + "' binds ':" + found[j] + "', which is not a declared param"])
                    end if
                    j += 1
                end while
            end if
            enc = v["encoding"]
            if is_unknown(enc) then
                errors = concat(errors, ["visual '" + vn + "' has no 'encoding'"])
            else
                mk = enc["mark"]
                if is_unknown(mk) then
                    errors = concat(errors, ["visual '" + vn + "' encoding has no 'mark'"])
                else if not contains(["bar", "line", "value", "table"], mk) then
                    errors = concat(errors, ["visual '" + vn + "' uses mark '" + string(mk) + "'; this build renders bar, line, value and table"])
                else if mk = "bar" or mk = "line" then
                    if is_unknown(enc["x"]) or is_unknown(enc["y"]) then
                        errors = concat(errors, ["visual '" + vn + "' mark '" + string(mk) + "' needs both 'x' and 'y' channels"])
                    end if
                else if mk = "value" then
                    if is_unknown(enc["value"]) then
                        errors = concat(errors, ["visual '" + vn + "' mark 'value' needs a 'value' channel"])
                    end if
                else if mk = "table" then
                    ' A table takes no positional channels: the SQL decides
                    ' shape, so x/y/series on a table is a misunderstanding
                    ' worth naming rather than ignoring.
                    if not is_unknown(enc["x"]) or not is_unknown(enc["y"]) or not is_unknown(enc["series"]) then
                        errors = concat(errors, ["visual '" + vn + "' mark 'table' takes no x, y or series channel; it renders result columns in SELECT order"])
                    end if
                end if

                ' 'series' belongs only to marks that can fan out.
                if not is_unknown(enc["series"]) then
                    if not contains(["bar", "line"], mk) then
                        errors = concat(errors, ["visual '" + vn + "' sets 'series', which only mark 'bar' or 'line' uses"])
                    end if
                end if

                ' format names must be ones this build renders.
                if not is_unknown(enc["format"]) then
                    if not gdash_format.known(enc["format"]) then
                        errors = concat(errors, ["visual '" + vn + "' uses format '" + string(enc["format"]) + "'; this build renders currency, number, percent and text"])
                    end if
                end if
                fmts = enc["formats"]
                if not is_unknown(fmts) then
                    if mk != "table" then
                        errors = concat(errors, ["visual '" + vn + "' sets 'formats', which only mark 'table' uses"])
                    end if
                    fc = keys(fmts)
                    k = 0
                    while k < count(fc)
                        entry = fmts[fc[k]]
                        if type(entry) = "record" then
                            fname = default(entry["name"], "text")
                        else
                            fname = string(entry)
                        end if
                        if not gdash_format.known(fname) then
                            errors = concat(errors, ["visual '" + vn + "' formats column '" + fc[k] + "' as '" + fname + "'; this build renders currency, number, percent and text"])
                        end if
                        k += 1
                    end while
                end if

                ' a currency must be one the build can construct
                if not is_unknown(enc["currency"]) then
                    if not contains(gdash_format.supported_currencies(), enc["currency"]) then
                        errors = concat(errors, ["visual '" + vn + "' names currency '" + string(enc["currency"]) + "', which this build does not support"])
                    end if
                end if
            end if
            i += 1
        end while

        ' --- controls ---
        controls = rec["controls"]
        if is_unknown(controls) then
            controls = {}
        end if
        ctl_names = keys(controls)
        i = 0
        while i < count(ctl_names)
            cnm = ctl_names[i]
            c = controls[cnm]
            if c["kind"] != "select" then
                errors = concat(errors, ["control '" + cnm + "' has kind '" + string(c["kind"]) + "'; this build implements 'select'"])
            end if
            if not _has(c, "param") then
                errors = concat(errors, ["control '" + cnm + "' has no 'param'"])
            else if not contains(param_names, c["param"]) then
                errors = concat(errors, ["control '" + cnm + "' publishes ':" + string(c["param"]) + "', which is not a declared param"])
            end if
            if _has(c, "dataset") then
                if not contains(ds_names, c["dataset"]) then
                    errors = concat(errors, ["control '" + cnm + "' names undefined dataset '" + string(c["dataset"]) + "'"])
                end if
            end if
            i += 1
        end while

        ' --- layout ---
        tabs = rec["tabs"]
        if is_unknown(tabs) or type(tabs) != "array" then
            errors = concat(errors, ["record has no 'tabs' array"])
        else if count(tabs) = 0 then
            errors = concat(errors, ["record has no tabs"])
        else
            i = 0
            while i < count(tabs)
                tb = tabs[i]
                if is_unknown(tb["name"]) then
                    errors = concat(errors, ["tab[" + string(i) + "] has no 'name'"])
                end if
                lay = tb["layout"]
                if is_unknown(lay) then
                    errors = concat(errors, ["tab[" + string(i) + "] has no 'layout'"])
                else
                    errors = _validate_layout(lay, vis_names, ctl_names, errors, "tab[" + string(i) + "].layout")
                    warnings = _walk_warnings(lay, "tab[" + string(i) + "].layout", warnings)
                end if
                i += 1
            end while
        end if

        return { errors: errors, warnings: warnings }
    end function

    ' The dependency graph, derived: which visuals re-run when `param` changes
    ' (design §2). A visual that does not bind the param deliberately stays put.
    function visuals_binding(rec, param)
        out = []
        visuals = rec["visuals"]
        if is_unknown(visuals) then
            return out
        end if
        names = keys(visuals)
        i = 0
        while i < count(names)
            v = visuals[names[i]]
            if not is_unknown(v["sql"]) then
                if contains(gdash_sql.bindings(v["sql"]), param) then
                    out = concat(out, [names[i]])
                end if
            end if
            i += 1
        end while
        return out
    end function

    ' Params resolved for a request: declared defaults overlaid with supplied
    ' values. Only declared params are honoured; anything else is ignored
    ' rather than passed through to SQL.
    function resolve_params(rec, supplied)
        out = {}
        params = rec["params"]
        if is_unknown(params) then
            return out
        end if
        names = keys(params)
        i = 0
        while i < count(names)
            nm = names[i]
            out[nm] = params[nm]["default"]
            if not is_unknown(supplied) then
                got = supplied[nm]
                if not is_unknown(got) then
                    out[nm] = got
                end if
            end if
            i += 1
        end while
        return out
    end function

end library
