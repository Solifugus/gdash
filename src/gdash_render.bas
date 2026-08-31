' gdash — encoding to fragment.
'
' A visual is a dataset + a SQL query + an encoding: a mark plus a mapping of
' result columns onto channels (design §2). This module translates that into a
' call on gBASIC's chart library; per the Studio rule the drawing belongs to
' the library, and gdash couples to it only through mark and channel names.
'
' Money is formatted from exact decimal TEXT, not through the money type.
' Design §4 says rendering divides through gBASIC's exact money type, but that
' type is double-backed: it refuses a string and renders
' 90071992547409.93 as 90071992547409.94 (finding F5). String surgery on
' minor units is exact at every magnitude, so that is what the format layer
' uses. Chart GEOMETRY still goes through doubles -- a bar's height is
' pixels -- but every value a human reads comes from the text.

library gdash_render

    ' `load` takes a compile-time literal, so the chart library's location
    ' cannot go through the resolver the way gdash's own paths do. The sibling
    ' layout CLAUDE.md documents (~/development/gbasic) is what this resolves
    ' against; an installed build needs a real answer here, recorded as a
    ' finding.
    load chart from "../../gbasic/stdlib/chart.bas"
    load gdash_store from "gdash_store.bas"
    load gdash_format from "gdash_format.bas"

    ' The one HTML escaper in gdash. gdash_app had a byte-identical copy until
    ' library_collisions() reported the pair; two implementations of escaping
    ' is how one of them ends up missing a case.
    function html_escape(text)
        t = replace(string(text), "&", "&amp;")
        t = replace(t, "<", "&lt;")
        t = replace(t, ">", "&gt;")
        t = replace(t, chr(34), "&quot;")
        return t
    end function

    ' The scale for a formatted channel comes from the dataset's own money
    ' columns: an aggregate of minor units is still minor units at the same
    ' scale. This phase requires the dataset's money columns to agree on a
    ' scale, which the reference record satisfies; a per-channel scale is
    ' GDASH-1's business along with the rest of the format map.
    function money_scale(db_path, attach)
        cols = gdash_store.money_columns(db_path, attach)
        names = keys(cols)
        if count(names) = 0 then
            return -1
        end if
        first = cols[names[0]]
        i = 1
        while i < count(names)
            if cols[names[i]] != first then
                return -2
            end if
            i += 1
        end while
        return first
    end function

    ' The currency a money channel renders in. Declared on the encoding so a
    ' JPY column does not render as dollars; USD when unstated.
    function currency_of(visual)
        enc = visual["encoding"]
        return default(enc["currency"], "USD")
    end function

    function _err(message)
        return "<div class=" + chr(34) + "gdash-error" + chr(34) + ">" + html_escape(message) + "</div>"
    end function

    ' Channel validation happens here, against a real result set, because
    ' sqlite.columns has not shipped (finding F4). Design §2 names this
    ' fallback: until prepare-without-execute exists, channel checks happen at
    ' first refresh rather than at load time.
    function _has_column(row, name)
        return contains(keys(row), name)
    end function

    ' The series channel fans rows out into one chart series per distinct
    ' value, in RESULT order -- the SQL decides the order, as it decides
    ' everything else about shape. A missing (x, series) pair stays `unknown`,
    ' which the chart library renders as a gap rather than a zero; a zero
    ' would be a claim the data never made.
    function _pivot(rows, xch, ych, sch, is_money, scale)
        xs = []
        names = []
        i = 0
        while i < count(rows)
            xv = string(rows[i][xch])
            if not contains(xs, xv) then
                xs = concat(xs, [xv])
            end if
            if sch != "" then
                sv = string(rows[i][sch])
                if not contains(names, sv) then
                    names = concat(names, [sv])
                end if
            end if
            i += 1
        end while
        if sch = "" then
            names = [ych]
        end if

        df = {}
        df[xch] = xs
        c = 0
        while c < count(names)
            col = []
            r = 0
            while r < count(xs)
                col = concat(col, [unknown])
                r += 1
            end while
            df[names[c]] = col
            c += 1
        end while

        i = 0
        while i < count(rows)
            xv = string(rows[i][xch])
            slot = find(xs, xv)
            key = ych
            if sch != "" then
                key = string(rows[i][sch])
            end if
            if is_money then
                raw = rows[i][ych + "__text"]
                v = number(gdash_format.minor_to_decimal(raw, scale))
            else
                v = rows[i][ych]
            end if
            col = df[key]
            col[slot] = v
            df[key] = col
            i += 1
        end while
        return { xs: xs, names: names, df: df }
    end function

    function render_visual(name, visual, rows, db_path, attach)
        enc = visual["encoding"]
        mark = enc["mark"]

        if count(rows) = 0 then
            return "<div class=" + chr(34) + "gdash-empty" + chr(34) + ">No data</div>"
        end if
        row0 = rows[0]

        is_money = enc["format"] = "currency"
        scale = 0
        if mark = "table" then
            probe = money_scale(db_path, attach)
            if probe > 0 then
                scale = probe
            else
                scale = 2
            end if
        end if
        if is_money then
            scale = money_scale(db_path, attach)
            if scale = -1 then
                return _err("visual '" + name + "' formats as currency but its dataset declares no money column")
            end if
            if scale = -2 then
                return _err("visual '" + name + "' formats as currency but its dataset's money columns disagree on scale")
            end if
        end if

        if mark = "value" then
            ch = enc["value"]
            if not _has_column(row0, ch) then
                return _err("visual '" + name + "': channel 'value' names column '" + string(ch) + "', which the query does not return")
            end if
            if is_money then
                exact = row0[ch + "__text"]
                if is_unknown(exact) then
                    return _err("visual '" + name + "': money channel was not fetched exactly")
                end if
                got = gdash_format.currency(exact, scale, currency_of(visual))
                if not got.ok then
                    return _err("visual '" + name + "': " + got.message)
                end if
                shown = got.text
            else
                shown = string(row0[ch])
            end if
            title = default(enc["title"], "")
            return "<div class=" + chr(34) + "gdash-value" + chr(34) + "><div class=" + chr(34) + "gdash-value-title" + chr(34) + ">" + html_escape(title) + "</div><div class=" + chr(34) + "gdash-value-number" + chr(34) + ">" + html_escape(shown) + "</div></div>"
        end if

        if mark = "bar" or mark = "line" then
            xch = enc["x"]
            ych = enc["y"]
            if not _has_column(row0, xch) then
                return _err("visual '" + name + "': channel 'x' names column '" + string(xch) + "', which the query does not return")
            end if
            if not _has_column(row0, ych) then
                return _err("visual '" + name + "': channel 'y' names column '" + string(ych) + "', which the query does not return")
            end if
            sch = ""
            if not is_unknown(enc["series"]) then
                sch = enc["series"]
                if not _has_column(row0, sch) then
                    return _err("visual '" + name + "': channel 'series' names column '" + string(sch) + "', which the query does not return")
                end if
            end if

            shaped = _pivot(rows, xch, ych, sch, is_money, scale)
            on error goto next
            if mark = "bar" then
                svg = chart.bar(shaped.df, xch, shaped.names)
            else
                svg = chart.line(shaped.df, xch, shaped.names)
            end if
            if error then
                return _err("visual '" + name + "': chart library refused the data: " + error.message)
            end if
            return svg
        end if

        if mark = "table" then
            ' The table mark renders result columns in SELECT ORDER with a
            ' per-column formats map (design §2). No column list, no ordering
            ' options, no aggregation: the SQL stays the single place shape is
            ' decided.
            fmts = enc["formats"]
            if is_unknown(fmts) then
                fmts = {}
            end if
            cols = []
            all_cols = keys(row0)
            i = 0
            while i < count(all_cols)
                cn = all_cols[i]
                ' the __text siblings are the exactness mechanism, not data
                if not ends_with(cn, "__text") then
                    cols = concat(cols, [cn])
                end if
                i += 1
            end while

            head = []
            i = 0
            while i < count(cols)
                head = concat(head, ["<th>" + html_escape(cols[i]) + "</th>"])
                i += 1
            end while

            body = []
            r = 0
            while r < count(rows)
                cells = []
                c = 0
                while c < count(cols)
                    cn = cols[c]
                    entry = fmts[cn]
                    if is_unknown(entry) then
                        shown = string(rows[r][cn])
                    else
                        spec = format_spec(entry, scale, currency_of(visual))
                        shown = gdash_format.apply(spec, rows[r][cn], rows[r][cn + "__text"])
                    end if
                    cells = concat(cells, ["<td>" + html_escape(shown) + "</td>"])
                    c += 1
                end while
                body = concat(body, ["<tr>" + join(cells, "") + "</tr>"])
                r += 1
            end while

            title = default(enc["title"], "")
            return "<div class=" + chr(34) + "gdash-table" + chr(34) + "><div class=" + chr(34) + "gdash-table-title" + chr(34) + ">" + html_escape(title) + "</div><table><thead><tr>" + join(head, "") + "</tr></thead><tbody>" + join(body, "") + "</tbody></table></div>"
        end if

        return _err("visual '" + name + "' uses mark '" + string(mark) + "', which this build does not render")
    end function

    ' Which result columns of a visual query must cross exactly (the F1 text
    ' boundary): every channel this encoding formats as currency.
    function exact_columns(visual)
        enc = visual["encoding"]
        mark = enc["mark"]
        if mark = "table" then
            out = []
            fmts = enc["formats"]
            if is_unknown(fmts) then
                return out
            end if
            cols = keys(fmts)
            i = 0
            while i < count(cols)
                if format_name(fmts[cols[i]]) = "currency" then
                    out = concat(out, [cols[i]])
                end if
                i += 1
            end while
            return out
        end if
        if enc["format"] != "currency" then
            return []
        end if
        if mark = "value" then
            return [enc["value"]]
        end if
        if mark = "bar" or mark = "line" then
            return [enc["y"]]
        end if
        return []
    end function

    ' A formats entry is either a bare name ("currency") or a record carrying
    ' options ({ name: "number", decimals: 2 }). Both spellings are honoured
    ' because the short one is what most columns want and the long one is
    ' what the rest need.
    function format_name(entry)
        if type(entry) = "record" then
            return default(entry["name"], "text")
        end if
        return string(entry)
    end function

    function format_spec(entry, scale, code)
        nm = format_name(entry)
        spec = { name: nm, scale: scale, currency: code, decimals: 0 }
        if type(entry) = "record" then
            spec["decimals"] = default(entry["decimals"], 0)
            spec["currency"] = default(entry["currency"], code)
        end if
        if nm = "percent" and type(entry) != "record" then
            spec["decimals"] = 1
        end if
        return spec
    end function

    function render_control(name, control, options, current)
        opts = []
        i = 0
        while i < count(options)
            v = string(options[i])
            sel = ""
            if v = string(current) then
                sel = " selected"
            end if
            opts = concat(opts, ["<option value=" + chr(34) + html_escape(v) + chr(34) + sel + ">" + html_escape(v) + "</option>"])
            i += 1
        end while
        label = default(control["label"], name)
        return "<label class=" + chr(34) + "gdash-control" + chr(34) + ">" + html_escape(label) + " <select data-param=" + chr(34) + html_escape(control["param"]) + chr(34) + " onchange=" + chr(34) + "gdashParam(this)" + chr(34) + ">" + join(opts, "") + "</select></label>"
    end function

end library
