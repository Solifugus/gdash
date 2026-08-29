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

    function _html_escape(text)
        t = replace(string(text), "&", "&amp;")
        t = replace(t, "<", "&lt;")
        t = replace(t, ">", "&gt;")
        t = replace(t, chr(34), "&quot;")
        return t
    end function

    ' Thousands separators by string surgery, so the digits stay exact.
    function _group(digits)
        out = ""
        n = len(digits)
        i = 0
        while i < n
            if i > 0 and mod(n - i, 3) = 0 then
                out = out + ","
            end if
            out = out + mid(digits, i, 1)
            i += 1
        end while
        return out
    end function

    function format_currency(minor_text, scale)
        plain = gdash_store.from_minor(minor_text, scale)
        neg = false
        if starts_with(plain, "-") then
            neg = true
            plain = mid(plain, 1, len(plain) - 1)
        end if
        bits = split(plain, ".")
        whole = _group(bits[0])
        if count(bits) = 2 then
            body = "$" + whole + "." + bits[1]
        else
            body = "$" + whole
        end if
        if neg then
            return "-" + body
        end if
        return body
    end function

    ' The scale for a formatted channel comes from the dataset's own money
    ' columns: an aggregate of minor units is still minor units at the same
    ' scale. This phase requires the dataset's money columns to agree on a
    ' scale, which the reference record satisfies; a per-channel scale is
    ' GDASH-1's business along with the rest of the format map.
    function money_scale(db_path)
        cols = gdash_store.money_columns(db_path)
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

    function _err(message)
        return "<div class=" + chr(34) + "gdash-error" + chr(34) + ">" + _html_escape(message) + "</div>"
    end function

    ' Channel validation happens here, against a real result set, because
    ' sqlite.columns has not shipped (finding F4). Design §2 names this
    ' fallback: until prepare-without-execute exists, channel checks happen at
    ' first refresh rather than at load time.
    function _has_column(row, name)
        return contains(keys(row), name)
    end function

    function render_visual(name, visual, rows, db_path)
        enc = visual["encoding"]
        mark = enc["mark"]

        if count(rows) = 0 then
            return "<div class=" + chr(34) + "gdash-empty" + chr(34) + ">No data</div>"
        end if
        row0 = rows[0]

        is_money = enc["format"] = "currency"
        scale = 0
        if is_money then
            scale = money_scale(db_path)
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
                shown = format_currency(exact, scale)
            else
                shown = string(row0[ch])
            end if
            title = default(enc["title"], "")
            return "<div class=" + chr(34) + "gdash-value" + chr(34) + "><div class=" + chr(34) + "gdash-value-title" + chr(34) + ">" + _html_escape(title) + "</div><div class=" + chr(34) + "gdash-value-number" + chr(34) + ">" + _html_escape(shown) + "</div></div>"
        end if

        if mark = "bar" then
            xch = enc["x"]
            ych = enc["y"]
            if not _has_column(row0, xch) then
                return _err("visual '" + name + "': channel 'x' names column '" + string(xch) + "', which the query does not return")
            end if
            if not _has_column(row0, ych) then
                return _err("visual '" + name + "': channel 'y' names column '" + string(ych) + "', which the query does not return")
            end if
            cats = []
            vals = []
            i = 0
            while i < count(rows)
                cats = concat(cats, [string(rows[i][xch])])
                if is_money then
                    exact = rows[i][ych + "__text"]
                    ' Geometry is pixels, so the double is harmless here; the
                    ' exact text is what any label would show.
                    vals = concat(vals, [number(gdash_store.from_minor(exact, scale))])
                else
                    vals = concat(vals, [rows[i][ych]])
                end if
                i += 1
            end while
            on error goto next
            svg = chart.bar_xy(cats, vals)
            if error then
                return _err("visual '" + name + "': chart library refused the data: " + error.message)
            end if
            return svg
        end if

        return _err("visual '" + name + "' uses mark '" + string(mark) + "', which this build does not render")
    end function

    ' Which result columns of a visual query must cross exactly (design §4.3
    ' text boundary): the channel the encoding formats as currency.
    function exact_columns(visual)
        enc = visual["encoding"]
        if enc["format"] != "currency" then
            return []
        end if
        if enc["mark"] = "value" then
            return [enc["value"]]
        end if
        if enc["mark"] = "bar" then
            return [enc["y"]]
        end if
        return []
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
            opts = concat(opts, ["<option value=" + chr(34) + _html_escape(v) + chr(34) + sel + ">" + _html_escape(v) + "</option>"])
            i += 1
        end while
        label = default(control["label"], name)
        return "<label class=" + chr(34) + "gdash-control" + chr(34) + ">" + _html_escape(label) + " <select data-param=" + chr(34) + _html_escape(control["param"]) + chr(34) + " onchange=" + chr(34) + "gdashParam(this)" + chr(34) + ">" + join(opts, "") + "</select></label>"
    end function

end library
