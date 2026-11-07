' gdash — encoding channels, checked against what a query really returns.
'
' Design §2's load-time red/green had one gap: a channel naming a column the
' query does not return was found by whoever OPENED the dashboard, as an error
' box in one visual, because nothing could say what a query returns without
' running it. G-SQL can now (`db.columns`, GDASH-20 ask A2), so `validate`
' says it and `publish` refuses it (GDASH-21).
'
' Two limits, stated where they bite:
'   - the dashboard's data must exist: a column list comes from the plan,
'     and a table that has never refreshed has no plan. Such a visual is
'     reported as NOT CHECKED, never as passing;
'   - most computed columns (`sum(amount)`) are described as kind `any`, so
'     the kind check below is a WARNING about plain columns only.

library gdash_channels

    load gdash_store from "gdash_store.bas"

    ' The columns an encoding names, as { channel, column } pairs. A `table`
    ' names columns through its `formats` map; every other mark through its
    ' channels. Optional channels count only when set.
    function named(enc)
        out = []
        mark = string(default(enc["mark"], ""))
        wanted = []
        if mark = "value" then
            wanted = ["value"]
        else if mark = "pie" then
            wanted = ["label", "value"]
        else if contains(["bar", "line", "area", "scatter"], mark) then
            wanted = ["x", "y", "series"]
        end if
        for each ch in wanted
            if not is_unknown(enc[ch]) and string(enc[ch]) != "" then
                out = append(out, { channel: ch, column: string(enc[ch]) })
            end if
        next
        if mark = "table" and type(enc["formats"]) = "record" then
            for each col in keys(enc["formats"])
                out = append(out, { channel: "formats", column: col })
            next
        end if
        return out
    end function

    ' The column a currency format is applied to, for the kind warning.
    function _currency_columns(enc)
        out = []
        mark = string(default(enc["mark"], ""))
        if mark = "table" and type(enc["formats"]) = "record" then
            for each col in keys(enc["formats"])
                f = enc["formats"][col]
                nm = f
                if type(f) = "record" then
                    nm = default(f["name"], "")
                end if
                if string(nm) = "currency" then
                    out = append(out, col)
                end if
            next
        else if string(default(enc["format"], "")) = "currency" then
            ch = "y"
            if mark = "value" or mark = "pie" then
                ch = "value"
            end if
            if not is_unknown(enc[ch]) then
                out = append(out, string(enc[ch]))
            end if
        end if
        return out
    end function

    ' Kinds a currency format cannot mean anything over. A number renders as
    ' an amount in the stated currency, money in its own; text, dates and
    ' booleans are an author's mistake.
    function _not_an_amount(kind)
        return contains(["string", "date", "time", "datetime", "boolean"], string(kind))
    end function

    ' { errors, warnings, unchecked }, each a list of sentences naming the
    ' visual or control. `db_path` is the database the record's queries run
    ' against: the draft's, for a draft being validated or published.
    function check_channels(rec, db_path)
        errors = []
        warnings = []
        unchecked = []
        visuals = rec["visuals"]
        if type(visuals) != "record" then
            visuals = {}
        end if
        for each vn in sort(keys(visuals))
            v = visuals[vn]
            ds = string(default(v["dataset"], ""))
            if not gdash_store.has_dataset(db_path, ds) then
                unchecked = append(unchecked, "visual '" + vn + "': dataset '" + ds + "' has not refreshed, so its columns cannot be checked yet")
            else
                got = gdash_store.columns(db_path, string(v["sql"]))
                if not got.ok then
                    errors = append(errors, "visual '" + vn + "': its query does not compile against the staged data: " + got.message)
                else
                    kinds = {}
                    names = []
                    for each c in got.columns
                        kinds[string(c.name)] = string(c.kind)
                        names = append(names, string(c.name))
                    next
                    enc = v["encoding"]
                    if type(enc) != "record" then
                        enc = {}
                    end if
                    for each n in named(enc)
                        if not contains(names, n.column) then
                            where = "channel '" + n.channel + "'"
                            if n.channel = "formats" then
                                where = "a format"
                            end if
                            errors = append(errors, "visual '" + vn + "': " + where + " names column '" + n.column + "', which its query does not return (it returns " + join(names, ", ") + ")")
                        end if
                    next
                    for each col in _currency_columns(enc)
                        if contains(names, col) and _not_an_amount(kinds[col]) then
                            warnings = append(warnings, "visual '" + vn + "': '" + col + "' is formatted as currency, but it is " + kinds[col] + ", not an amount")
                        end if
                    next
                end if
            end if
        next
        controls = rec["controls"]
        if type(controls) = "record" then
            for each cn in sort(keys(controls))
                c = controls[cn]
                if not is_unknown(c["sql"]) then
                    ds = string(default(c["dataset"], ""))
                    if not gdash_store.has_dataset(db_path, ds) then
                        unchecked = append(unchecked, "control '" + cn + "': dataset '" + ds + "' has not refreshed, so its options cannot be checked yet")
                    else
                        got = gdash_store.columns(db_path, string(c["sql"]))
                        if not got.ok then
                            errors = append(errors, "control '" + cn + "': its options query does not compile against the staged data: " + got.message)
                        end if
                    end if
                end if
            next
        end if
        return { errors: errors, warnings: warnings, unchecked: unchecked }
    end function

end library
