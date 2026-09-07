' gdash — the theme.
'
' Server-level, <config>/theme.json, and deliberately small: a palette and a
' font size. A dashboard describes what it shows; how it looks belongs to the
' deployment, so that a company's dashboards agree with each other without
' every record repeating the same colours.
'
' ABSENT MEANS THE LIBRARY'S DEFAULTS, which are the Okabe-Ito palette --
' colourblind-safe by construction and a better default than gdash would have
' picked for itself. A theme file is an override, never a requirement.
'
' MALFORMED MEANS THE LIBRARY'S DEFAULTS TOO, and an error in the log. A
' theme is decoration: refusing to serve a dashboard because its colours are
' unreadable would be a worse failure than serving it in the wrong colours.
' That is the opposite of the ruling for users.json (a file gdash cannot read
' is a locked door quietly removed), and the difference is that one of them
' governs access and the other governs appearance.

library gdash_theme

    load gdash_paths from "gdash_paths.bas"

    ' `#rgb` or `#rrggbb`. Deliberately not accepting named colours or
    ' rgb(): the value goes straight into SVG markup, and a short, checkable
    ' grammar is what keeps it from being an injection surface.
    function legal_color(c)
        if type(c) != "string" then
            return false
        end if
        n = len(c)
        if n != 4 and n != 7 then
            return false
        end if
        if mid(c, 0, 1) != "#" then
            return false
        end if
        i = 1
        while i < n
            if not contains("0123456789abcdefABCDEF", mid(c, i, 1)) then
                return false
            end if
            i += 1
        end while
        return true
    end function

    ' Pure: handed the decoded value, never a path. Returns a list of errors.
    function check_theme(v)
        errors = []
        if type(v) != "record" then
            return ["theme must be a JSON object"]
        end if
        if v["format"] != 1 then
            errors = concat(errors, ["unsupported theme format: " + string(default(v["format"], "none")) + " (this build reads format 1)"])
        end if
        pal = v["palette"]
        if not is_unknown(pal) then
            if type(pal) != "array" then
                errors = concat(errors, ["'palette' must be an array of colours"])
            else if count(pal) = 0 then
                errors = concat(errors, ["'palette' is empty; leave it out to use the built-in one"])
            else
                i = 0
                while i < count(pal)
                    if not legal_color(pal[i]) then
                        errors = concat(errors, ["palette entry " + string(i) + " is not a colour like '#1a2b3c' or '#abc'"])
                    end if
                    i += 1
                end while
            end if
        end if
        fs = v["font_size"]
        if not is_unknown(fs) then
            if type(fs) != "number" or fs < 6 or fs > 48 then
                errors = concat(errors, ["'font_size' must be a number between 6 and 48"])
            end if
        end if
        return errors
    end function

    function default_theme()
        return { format: 1 }
    end function

    ' { ok, theme, errors }. `ok` false always comes with the empty theme, so
    ' a caller that ignores the errors still renders something sane.
    function load_theme(p)
        path = gdash_paths.theme_file(p)
        if not gdash_paths.path_exists(path) then
            return { ok: true, theme: default_theme(), errors: [] }
        end if
        on error goto next
        f {file} = path
        txt = read(f)
        if error then
            return { ok: false, theme: default_theme(), errors: ["theme file unreadable: " + path] }
        end if
        parsed = try_decode(txt)
        if error or not parsed.ok then
            return { ok: false, theme: default_theme(), errors: ["theme is not valid JSON: " + path] }
        end if
        problems = check_theme(parsed.value)
        if count(problems) > 0 then
            return { ok: false, theme: default_theme(), errors: problems }
        end if
        return { ok: true, theme: parsed.value, errors: [] }
    end function

    ' The chart options a theme contributes DIRECTLY -- which is font size and
    ' nothing else. Only keys the theme actually carries, because chart merges
    ' blindly and an `unknown` would overwrite a good default with nothing
    ' (finding G7-5).
    '
    ' The palette is NOT here, deliberately: it cannot be a plain theme value
    ' because a record may override individual series, so it has to be built
    ' against the names being drawn. `palette_for` is its accessor. This
    ' function returned it too until a mutation test showed that nothing
    ' noticed when it stopped -- it was dead the day it was written, because
    ' the render path already called palette_for.
    function options_for(theme)
        opts = {}
        if is_unknown(theme) then
            return opts
        end if
        if not is_unknown(theme["font_size"]) then
            opts["font_size"] = theme["font_size"]
        end if
        return opts
    end function

    ' The eight the library ships: Okabe-Ito, colourblind-safe by
    ' construction. Used as the fallback and as the EXTENSION of a short theme.
    function builtin_palette()
        return ["#000000", "#E69F00", "#56B4E9", "#009E73",
                "#F0E442", "#0072B2", "#D55E00", "#CC79A7"]
    end function

    ' The palette a visual actually draws with, once a record has had its say.
    '
    ' `chart` applies a palette in SERIES ORDER and REFUSES A CHART whose
    ' palette is shorter than its series -- "3 series but the palette has 2
    ' colors" reaching a viewer as an error box, which is an operator's problem
    ' shown to the wrong person. So this always returns exactly as many colours
    ' as there are names.
    '
    ' A short theme is EXTENDED from the built-in palette rather than cycled:
    ' cycling would give two series the same colour, and two series you cannot
    ' tell apart is a worse chart than one that used a colour the operator did
    ' not pick. The theme is a preference, not a ceiling.
    function _nth_colour(base, k)
        if k < count(base) then
            return base[k]
        end if
        extra = builtin_palette()
        return extra[mod(k - count(base), count(extra))]
    end function

    function palette_for(theme, names, colors)
        base = theme["palette"]
        if is_unknown(base) or count(base) = 0 then
            base = builtin_palette()
        end if
        if count(names) = 0 then
            return base
        end if
        out = []
        next_base = 0
        i = 0
        while i < count(names)
            want = unknown
            if not is_unknown(colors) then
                want = colors[names[i]]
            end if
            if not is_unknown(want) and legal_color(want) then
                out = concat(out, [string(want)])
            else
                out = concat(out, [_nth_colour(base, next_base)])
                next_base += 1
            end if
            i += 1
        end while
        return out
    end function

end library
