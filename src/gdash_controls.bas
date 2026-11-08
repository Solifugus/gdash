' gdash — the controls beyond a single select (GDASH-19).
'
' A date range and a multi-select. Both publish params, so neither needs a
' binding mechanism of its own: the dependency graph is still derived from the
' `:name`s in the SQL (design §2).
'
' THE DATE RANGE carries an EXPRESSION, not two dates. "Last 30 days"
' bookmarked in March must not still mean March in June, so the page and the
' URL hold `last_30d` and the server resolves it on every request, into the
' two date params the SQL binds. The vocabulary is CLOSED (ruling 2,
' 2026-09-30), which is what lets the record be validated at load time.
'
' THE MULTI-SELECT carries `|a|b|`, the convention `user_groups` already uses:
' delimiters on BOTH ends, so `:regions like '%|' || region || '|%'` cannot
' match a value that merely ends in a selected one.

library gdash_controls

    function kinds()
        return ["select", "multiselect", "daterange"]
    end function

    function range_vocabulary()
        return ["today", "last_7d", "last_30d", "last_90d", "mtd", "qtd", "ytd", "last_month", "last_quarter", "last_year", "custom"]
    end function

    function _date(y, m, d)
        mm = string(m)
        if len(mm) < 2 then
            mm = "0" + mm
        end if
        dd = string(d)
        if len(dd) < 2 then
            dd = "0" + dd
        end if
        out {date}= string(y) + "-" + mm + "-" + dd
        return out
    end function

    function _quarter_start(t)
        m = t.month - mod(t.month - 1, 3)
        return _date(t.year, m, 1)
    end function

    ' An expression as two dates, inclusive, against `today` -- a date value
    ' the caller supplies, so a test pins the vocabulary with no wall clock in
    ' it. `custom` is not resolved here: its two dates are the params' own.
    ' { ok, from, to, message }
    function range_dates(expr, today)
        t = today
        if expr = "today" then
            return { ok: true, from: t, to: t, message: "" }
        end if
        if expr = "last_7d" then
            return { ok: true, from: t - 6 days, to: t, message: "" }
        end if
        if expr = "last_30d" then
            return { ok: true, from: t - 29 days, to: t, message: "" }
        end if
        if expr = "last_90d" then
            return { ok: true, from: t - 89 days, to: t, message: "" }
        end if
        if expr = "mtd" then
            return { ok: true, from: _date(t.year, t.month, 1), to: t, message: "" }
        end if
        if expr = "qtd" then
            return { ok: true, from: _quarter_start(t), to: t, message: "" }
        end if
        if expr = "ytd" then
            return { ok: true, from: _date(t.year, 1, 1), to: t, message: "" }
        end if
        if expr = "last_month" then
            first = _date(t.year, t.month, 1)
            prev = first - 1 day
            return { ok: true, from: _date(prev.year, prev.month, 1), to: prev, message: "" }
        end if
        if expr = "last_quarter" then
            qs = _quarter_start(t)
            prev = qs - 1 day
            return { ok: true, from: _quarter_start(prev), to: prev, message: "" }
        end if
        if expr = "last_year" then
            return { ok: true, from: _date(t.year - 1, 1, 1), to: _date(t.year - 1, 12, 31), message: "" }
        end if
        return { ok: false, from: unknown, to: unknown, message: "'" + string(expr) + "' is not a range; the ranges are " + join(range_vocabulary(), ", ") }
    end function

    ' Today, as a date. The one place the wall clock enters.
    function today()
        d {date}= now()
        return d
    end function

    ' Every date range's two params, resolved from its expression. `values` is
    ' what resolve_params produced; the expression param is left as it came,
    ' so the page and the URL keep the expression. `custom` keeps the from/to
    ' values as supplied, so an absolute range round-trips untouched.
    function apply_ranges(rec, values, today_date)
        out = values
        controls = rec["controls"]
        if type(controls) != "record" then
            return out
        end if
        for each cn in keys(controls)
            c = controls[cn]
            if string(default(c["kind"], "")) = "daterange" then
                expr = string(default(out[string(c["param"])], ""))
                if expr != "custom" then
                    got = range_dates(expr, today_date)
                    if got.ok then
                        out[string(c["from"])] = got.from
                        out[string(c["to"])] = got.to
                    end if
                end if
            end if
        next
        return out
    end function

    ' Supplied values a control refuses: a range expression outside the
    ' vocabulary, and a multi-select value that is not a `|a|b|` list. Each
    ' named, so the caller can answer 400 before any query runs.
    function control_param_errors(rec, supplied)
        out = []
        controls = rec["controls"]
        if type(controls) != "record" or is_unknown(supplied) then
            return out
        end if
        for each cn in keys(controls)
            c = controls[cn]
            kind = string(default(c["kind"], ""))
            pn = string(default(c["param"], ""))
            v = supplied[pn]
            if not is_unknown(v) then
                if kind = "daterange" and not contains(range_vocabulary(), string(v)) then
                    out = append(out, "param '" + pn + "': " + range_dates(string(v), today()).message)
                else if kind = "multiselect" and not list_shaped(string(v)) then
                    out = append(out, "param '" + pn + "' must be a list written |a|b|, delimiters at both ends")
                end if
            end if
        next
        return out
    end function

    ' `||` (nothing chosen) or `|a|` or `|a|b|`: delimiters at both ends, and
    ' no empty member between them.
    function list_shaped(v)
        if v = "||" then
            return true
        end if
        if len(v) < 3 or not starts_with(v, "|") or not ends_with(v, "|") then
            return false
        end if
        parts = split(mid(v, 1, len(v) - 2), "|")
        for each part in parts
            if part = "" then
                return false
            end if
        next
        return true
    end function

    ' The members of a `|a|b|` list.
    function members(v)
        if not list_shaped(v) or v = "||" then
            return []
        end if
        return split(mid(v, 1, len(v) - 2), "|")
    end function

    ' A list from members. A member containing the delimiter cannot be
    ' represented without escaping its own list, so it is left out -- and the
    ' caller is told how many were, rather than having them vanish.
    function list_of(vals)
        kept = []
        dropped = 0
        for each x in vals
            sx = string(x)
            if contains(sx, "|") or sx = "" then
                dropped += 1
            else
                kept = append(kept, sx)
            end if
        next
        if count(kept) = 0 then
            return { list: "||", dropped: dropped }
        end if
        return { list: "|" + join(kept, "|") + "|", dropped: dropped }
    end function

    ' Validation of the two new kinds, against the record's params and
    ' datasets. Returns sentences; the record validator adds them to its own.
    function validate_control(cnm, c, params, datasets)
        errs = []
        kind = string(default(c["kind"], ""))
        pn = string(default(c["param"], ""))
        if kind = "multiselect" then
            if not is_unknown(params[pn]) then
                dv = params[pn]["default"]
                if not is_unknown(dv) and not list_shaped(string(dv)) then
                    errs = append(errs, "control '" + cnm + "' publishes '" + pn + "', whose default '" + string(dv) + "' is not a list written |a|b| (|| for none)")
                end if
            end if
        end if
        if kind = "daterange" then
            if not is_unknown(params[pn]) then
                dv = string(default(params[pn]["default"], ""))
                if not contains(range_vocabulary(), dv) then
                    errs = append(errs, "control '" + cnm + "' publishes '" + pn + "', whose default '" + dv + "' is not a range; the ranges are " + join(range_vocabulary(), ", "))
                end if
            end if
            for each side in ["from", "to"]
                sp = string(default(c[side], ""))
                if sp = "" then
                    errs = append(errs, "control '" + cnm + "' is a date range with no '" + side + "' param")
                else if is_unknown(params[sp]) then
                    errs = append(errs, "control '" + cnm + "' names '" + side + "' param '" + sp + "', which is not a declared param")
                else if string(default(params[sp]["type"], "")) != "date" then
                    errs = append(errs, "control '" + cnm + "' names '" + side + "' param '" + sp + "', which must be declared with type date")
                end if
            next
            col = string(default(c["column"], ""))
            ds = string(default(c["dataset"], ""))
            if col = "" or ds = "" then
                errs = append(errs, "control '" + cnm + "' is a date range and must name its 'dataset' and 'column'")
            else if not is_unknown(datasets[ds]) then
                decl = unknown
                if type(datasets[ds]["columns"]) = "record" then
                    decl = datasets[ds]["columns"][col]
                end if
                if is_unknown(decl) or string(default(decl["type"], "")) != "date" then
                    errs = append(errs, "control '" + cnm + "' ranges over '" + ds + "." + col + "', which is not declared {\"type\": \"date\"}")
                end if
            end if
        end if
        return errs
    end function

end library
