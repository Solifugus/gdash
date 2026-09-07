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
    load chart
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
    ' Returns { xs, keys, names, df, x_numeric }.
    '
    ' `keys` is the string form of each x value, used for slotting rows; `xs`
    ' is the x column AS IT WILL REACH THE CHART. Those were the same list
    ' until GDASH-7, and that was the bug (finding G7-3): every x value was
    ' stringified, so a line, area or scatter chart -- which needs a numeric x
    ' to place a point -- received categories and drew NOTHING. It returned a
    ' complete SVG with axes, gridlines and labels, and no data. gdash shipped
    ' a reference dashboard with a blank line chart through six phases.
    '
    ' `x_numeric` is what the caller uses to refuse rather than render an
    ' empty frame.
    function _pivot(rows, xch, ych, sch, is_money, scale)
        xs = []
        keys = []
        names = []
        x_numeric = true
        i = 0
        while i < count(rows)
            raw_x = rows[i][xch]
            xv = string(raw_x)
            if type(raw_x) != "number" then
                x_numeric = false
            end if
            if not contains(keys, xv) then
                keys = concat(keys, [xv])
                xs = concat(xs, [raw_x])
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
            while r < count(keys)
                col = concat(col, [unknown])
                r += 1
            end while
            df[names[c]] = col
            c += 1
        end while

        i = 0
        while i < count(rows)
            xv = string(rows[i][xch])
            slot = find(keys, xv)
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
        return { xs: xs, keys: keys, names: names, df: df, x_numeric: x_numeric }
    end function

    ' Encoding -> chart options. Only keys the record actually carries are
    ' passed: chart merges blindly (G7-5), so sending an `unknown` would
    ' overwrite a sensible default with nothing.
    '
    ' The legend defaults to ON when a `series` channel fanned the query out
    ' into several columns, and OFF otherwise -- one line needs no key to tell
    ' you which line it is. An explicit `legend` in the record wins either way.
    function _chart_options(enc, sch)
        opts = {}
        t = string(default(enc["title"], ""))
        if t != "" then
            opts["title"] = t
        end if
        xl = string(default(enc["x_label"], ""))
        if xl != "" then
            opts["x_label"] = xl
        end if
        yl = string(default(enc["y_label"], ""))
        if yl != "" then
            opts["y_label"] = yl
        end if
        opts["legend"] = sch != ""
        if not is_unknown(enc["legend"]) then
            opts["legend"] = enc["legend"] = true
        end if
        if not is_unknown(enc["stacked"]) then
            opts["stacked"] = enc["stacked"] = true
        end if
        if not is_unknown(enc["grid"]) then
            opts["grid"] = enc["grid"] = true
        end if
        if not is_unknown(enc["y_min"]) then
            opts["y_min"] = enc["y_min"]
        end if
        if not is_unknown(enc["y_max"]) then
            opts["y_max"] = enc["y_max"]
        end if
        return opts
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

        ' A pie has no axes: one value column, sliced by a label. It reuses
        ' _pivot's money handling by going through it with the label as x and
        ' no series, which is exactly the "one column per name" shape _pivot
        ' already produces.
        if mark = "pie" then
            lch = enc["label"]
            vch = enc["value"]
            if not _has_column(row0, lch) then
                return _err("visual '" + name + "': channel 'label' names column '" + string(lch) + "', which the query does not return")
            end if
            if not _has_column(row0, vch) then
                return _err("visual '" + name + "': channel 'value' names column '" + string(vch) + "', which the query does not return")
            end if
            shaped = _pivot(rows, lch, vch, "", is_money, scale)
            on error goto next
            sp = chart.spec("pie", shaped.df)
            sp = chart.x(sp, lch)
            sp = chart.y(sp, [vch])
            sp = chart.options(sp, _chart_options(enc, ""))
            svg = chart.render(sp)
            if error then
                return _err("visual '" + name + "': chart library refused the data: " + error.message)
            end if
            return svg
        end if

        if contains(["bar", "line", "area", "scatter"], mark) then
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

            ' A line places points along a numeric axis. Given categories it
            ' draws NOTHING and still returns a complete chart -- axes,
            ' gridlines, labels and no data (finding G7-3). An empty chart that
            ' looks like a chart is worse than an error: the viewer reads it as
            ' "no data" and the author reads it as "working". So gdash refuses
            ' here, where it holds the rows and can name the column. `bar`
            ' takes the same data correctly, and saying so is what turns the
            ' message into a fix.
            if mark != "bar" and not shaped.x_numeric then
                return _err("visual '" + name + "': mark '" + mark + "' needs a numeric 'x', and column '" + string(xch) + "' holds text -- use mark 'bar' for categories, or make the query return a number")
            end if

            ' THE SPEC CHAIN, not the convenience wrappers. `chart.bar(df, x,
            ' ycols)` takes no options at all, so every option in the record --
            ' title, axis labels, legend, stacked, range, grid -- is reachable
            ' only this way (finding G7-2). Until now a chart mark's `title`
            ' was accepted by the record and rendered by nobody.
            on error goto next
            sp = chart.spec(mark, shaped.df)
            sp = chart.x(sp, xch)
            sp = chart.y(sp, shaped.names)
            sp = chart.options(sp, _chart_options(enc, sch))
            svg = chart.render(sp)
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
