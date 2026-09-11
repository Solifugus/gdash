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
    load gdash_theme from "gdash_theme.bas"
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
    ' ONE ENTRY PER ROW, nothing deduplicated -- which is what a scatter is.
    ' The frame keeps every point, and a series channel gives each series its
    ' own y column with a gap where a row belongs to a different series, so no
    ' row is dropped and none is invented.
    function _points(rows, xch, ych, sch, is_money, scale)
        xs = []
        names = []
        seen_names = {}
        x_numeric = true
        i = 0
        while i < count(rows)
            raw_x = rows[i][xch]
            if type(raw_x) != "number" then
                x_numeric = false
            end if
            xs = append(xs, raw_x)
            if sch != "" then
                sv = string(rows[i][sch])
                if is_unknown(seen_names[sv]) then
                    seen_names[sv] = true
                    names = append(names, sv)
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
            nm = names[c]
            col = []
            i = 0
            while i < count(rows)
                mine = sch = ""
                if sch != "" then
                    mine = string(rows[i][sch]) = nm
                end if
                if mine then
                    if is_money then
                        col = append(col, number(gdash_format.minor_to_decimal(rows[i][ych + "__text"], scale)))
                    else
                        col = append(col, rows[i][ych])
                    end if
                else
                    col = append(col, unknown)
                end if
                i += 1
            end while
            df[nm] = col
            c += 1
        end while
        return { xs: xs, keys: xs, names: names, df: df, x_numeric: x_numeric, collapsed: "" }
    end function

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
        ' `append` MUTATES IN PLACE; `concat` COPIES. Measured on this build:
        ' twenty thousand appends take 40ms and twenty thousand concats take
        ' 9.7 SECONDS -- 242x. Every loop here runs once per row, so the
        ' difference is the difference between a chart and a timeout.
        '
        ' The `seen` record replaces a `contains(keys, xv)` scan per row, which
        ' was O(n^2) on top of that. Together they were costing three times the
        ' chart library's own rendering (finding G7-9).
        xs = []
        keys = []
        names = []
        seen = {}
        seen_names = {}
        seen_pairs = {}
        collapsed = ""
        x_numeric = true
        i = 0
        while i < count(rows)
            raw_x = rows[i][xch]
            xv = string(raw_x)
            if type(raw_x) != "number" then
                x_numeric = false
            end if
            if is_unknown(seen[xv]) then
                seen[xv] = count(keys)
                keys = append(keys, xv)
                xs = append(xs, raw_x)
            end if
            ' A repeat that MATTERS is the same (x, series) pair twice, because
            ' that is what lands in one slot and loses a row. Two regions at
            ' the same month are fine; one region twice at one month is not.
            '
            ' TWO LEVELS, NOT A JOINED KEY. The first version built
            ' `xv + chr(0) + series` and collided every pair sharing an x,
            ' because a NUL truncates a record key (finding G6-16) -- gdash's
            ' own finding, met from the other side. Any other separator is a
            ' character that can appear in the data.
            sv = ych
            if sch != "" then
                sv = string(rows[i][sch])
            end if
            at_x = seen_pairs[xv]
            if is_unknown(at_x) then
                at_x = {}
            end if
            if is_unknown(at_x[sv]) then
                at_x[sv] = true
                seen_pairs[xv] = at_x
            else if collapsed = "" then
                collapsed = xv
            end if
            if sch != "" then
                sv = string(rows[i][sch])
                if is_unknown(seen_names[sv]) then
                    seen_names[sv] = true
                    names = append(names, sv)
                end if
            end if
            i += 1
        end while
        if sch = "" then
            names = [ych]
        end if

        ' ONE PASS PER COLUMN, NOT ONE WRITE-BACK PER ROW.
        '
        ' Arrays are copy-on-write, so `col = df[key]` / `col[slot] = v` /
        ' `df[key] = col` copies the whole column on every row -- a read-append-
        ' write-back loop measures 467ms at four thousand iterations, and a
        ' mutation through an alias is not even visible. Building each column
        ' as a LOCAL that nothing else holds, and assigning it to the frame
        ' once, keeps the writes in place (finding G7-9).
        df = {}
        df[xch] = xs
        c = 0
        while c < count(names)
            nm = names[c]
            col = []
            r = 0
            while r < count(keys)
                col = append(col, unknown)
                r += 1
            end while
            i = 0
            while i < count(rows)
                key = ych
                if sch != "" then
                    key = string(rows[i][sch])
                end if
                if key = nm then
                    slot = seen[string(rows[i][xch])]
                    if is_money then
                        col[slot] = number(gdash_format.minor_to_decimal(rows[i][ych + "__text"], scale))
                    else
                        col[slot] = rows[i][ych]
                    end if
                end if
                i += 1
            end while
            df[nm] = col
            c += 1
        end while

        return { xs: xs, keys: keys, names: names, df: df, x_numeric: x_numeric, collapsed: collapsed }
    end function

    ' Encoding -> chart options. Only keys the record actually carries are
    ' passed: chart merges blindly (G7-5), so sending an `unknown` would
    ' overwrite a sensible default with nothing.
    '
    ' The legend defaults to ON when a `series` channel fanned the query out
    ' into several columns, and OFF otherwise -- one line needs no key to tell
    ' you which line it is. An explicit `legend` in the record wins either way.
    ' A chart whose marks publish a param on click. The wrapper carries the
    ' PARAM NAME; the marks carry the values, which the library put there. The
    ' shim needs both and neither is guessable from the other.
    '
    ' Nothing is wrapped unless the record opted in, so a dashboard that has
    ' not asked for this is byte-identical to before.
    function _clickable(enc, svg)
        pub = trim(string(default(enc["publishes"], "")))
        if pub = "" then
            return svg
        end if
        q = chr(34)
        return "<div class=" + q + "gdash-clickable" + q + " data-publishes=" + q + html_escape(pub) + q + ">" + svg + "</div>"
    end function

    function _chart_options(enc, sch, theme, names)
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

        ' AN AXIS THAT AGREES WITH THE NUMBERS BESIDE IT.
        '
        ' Derived, never declared. A visual already says `format: "currency"`
        ' with a `currency`, or `format: "percent"` -- so the axis is decided
        ' by what the record has already stated. Adding `y_prefix` to the
        ' record would be a SECOND place the format lives, and the second one
        ' is what gets forgotten and then disagrees with the first.
        '
        ' Only for marks with a y axis: a pie has none, and an option that
        ' cannot apply is one an author will wonder about.
        mk = string(default(enc["mark"], ""))

        ' Identifiers on the marks ONLY when a visual asked to publish a param
        ' from a click. Off otherwise, so every other chart's markup is
        ' byte-identical to what it was before this existed.
        if trim(string(default(enc["publishes"], ""))) != "" then
            opts["mark_keys"] = true
        end if

        if contains(["bar", "line", "area", "scatter"], mk) then
            fmt = string(default(enc["format"], ""))
            if fmt = "currency" then
                code = string(default(enc["currency"], ""))
                if code != "" then
                    opts["y_prefix"] = gdash_format.symbol_for(code)
                    opts["y_decimals"] = gdash_format.minor_places(code)
                end if
            else if fmt = "percent" then
                ' `_scale` is DISPLAY ONLY and moves no geometry, which is what
                ' makes a fraction readable as a percentage without charting a
                ' different number. gdash's percent_fmt multiplies by 100 for
                ' the same reason, so the axis and the table agree.
                opts["y_scale"] = 100
                opts["y_suffix"] = "%"
                opts["y_decimals"] = default(enc["decimals"], 1)
            end if
        end if

        ' The deployment's look, then the record's one override. font_size
        ' comes from the theme alone: a dashboard has no business deciding how
        ' big the type is on somebody else's wall.
        themed = gdash_theme.options_for(theme)
        if not is_unknown(themed["font_size"]) then
            opts["font_size"] = themed["font_size"]
        end if
        opts["palette"] = gdash_theme.palette_for(theme, names, enc["colors"])
        return opts
    end function

    function render_visual(name, visual, rows, db_path, attach, theme)
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
            sp = chart.options(sp, _chart_options(enc, "", theme, shaped.xs))
            svg = chart.render(sp)
            if error then
                return _err("visual '" + name + "': chart library refused the data: " + error.message)
            end if
            return _clickable(enc, svg)
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

            ' A SCATTER IS ONE POINT PER ROW. _pivot slots values by unique x
            ' and the last row wins, which silently dropped points: four
            ' readings with two at the same x drew three circles (finding
            ' G10-1). For a scatter that is data loss; for the marks that need
            ' one value per slot it is an AGGREGATION, and design §2 puts
            ' aggregation in the SQL -- so those refuse and name the column
            ' rather than quietly keeping a row at random.
            if mark = "scatter" then
                shaped = _points(rows, xch, ych, sch, is_money, scale)
            else
                shaped = _pivot(rows, xch, ych, sch, is_money, scale)
                if shaped.collapsed != "" then
                    return _err("visual '" + name + "': mark '" + mark + "' needs one value per '" + string(xch) + "', and '" + shaped.collapsed + "' appears more than once -- aggregate it in the query (group by), or use mark 'scatter' to plot every row")
                end if
            end if

            ' The numeric-x refusal that stood here is GONE. It existed
            ' because a text x made line, area and scatter draw nothing while
            ' returning a complete chart (G7-3); since gbasic a1f6da5 they
            ' place a non-numeric x at the same band centres `bar` uses, so a
            ' line and a bar of one frame line up column for column. gdash
            ' verified that against the installed library before deleting this.

            on error goto next
            sp = chart.spec(mark, shaped.df)
            sp = chart.x(sp, xch)
            sp = chart.y(sp, shaped.names)
            sp = chart.options(sp, _chart_options(enc, sch, theme, shaped.names))
            svg = chart.render(sp)
            if error then
                return _err("visual '" + name + "': chart library refused the data: " + error.message)
            end if
            return _clickable(enc, svg)
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
