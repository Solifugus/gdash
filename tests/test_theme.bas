' The theme: a palette and a font size, server-level.
'
' A dashboard describes what it shows; how it looks belongs to the deployment.
' The one exception is per-series colour, which a record may override because
' "that series is red in every other report in the company" is a real reason
' and nothing else about appearance is.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_theme from "../src/gdash_theme.bas"
    load gdash_render from "../src/gdash_render.bas"

    s = gdash_test.suite("theme")
    root = args[0]
    p = gdash_paths.roles(root)

    ' Start from no theme, whatever the harness handed us. The suite runner
    ' gives each case a fresh root, but a test that only passes because of
    ' that is a test that cannot be run on its own -- and running one on its
    ' own is exactly what you do when it fails.
    stale {file} = gdash_paths.theme_file(p)
    on error goto next
    if exists(stale) then
        delete(stale)
    end if

    ' --- colours -----------------------------------------------------------
    good = ["#abc", "#ABC", "#1a2b3c", "#FFFFFF", "#000000"]
    i = 0
    while i < count(good)
        s = gdash_test.ok(s, gdash_theme.legal_color(good[i]), "a colour: " + good[i])
        i += 1
    end while
    ' The value goes straight into SVG markup, so the grammar is short and
    ' checkable rather than permissive.
    bad = ["crimson", "#12345", "#gg0000", "rgb(1,2,3)", "", "#", "abc123",
           "#abc;fill:url(x)", "#ab", "#abcdefa"]
    i = 0
    while i < count(bad)
        s = gdash_test.ok(s, not gdash_theme.legal_color(bad[i]), "not a colour: <" + bad[i] + ">")
        i += 1
    end while
    s = gdash_test.ok(s, not gdash_theme.legal_color(7), "nor is a number")

    ' --- an absent theme is a complete configuration -----------------------
    absent = gdash_theme.load_theme(p)
    s = gdash_test.ok(s, absent.ok, "no theme file is not an error")
    s = gdash_test.eq(s, count(gdash_theme.options_for(absent.theme)), 0, "and contributes no options, leaving the library's own")
    s = gdash_test.eq(s, count(gdash_theme.palette_for(absent.theme, ["a", "b"], unknown)), 8, "falling back to the built-in eight-colour palette")

    ' --- a theme file ------------------------------------------------------
    made = gdash_paths.ensure_dir(p.config_dir)
    tf {file} = gdash_paths.theme_file(p)
    write(tf, encode({ format: 1, palette: ["#111111", "#222222"], font_size: 16 }))
    loaded = gdash_theme.load_theme(p)
    s = gdash_test.ok(s, loaded.ok, "a valid theme loads")
    opts = gdash_theme.options_for(loaded.theme)
    s = gdash_test.eq(s, opts["font_size"], 16, "contributing its font size")
    s = gdash_test.eq(s, join(opts["palette"], ","), "#111111,#222222", "and its palette")

    ' --- per-series override, in series order ------------------------------
    '
    ' chart applies a palette positionally, so the override is a palette built
    ' to match the names being drawn. A name the record did not colour takes
    ' the next UNUSED theme colour, not the one at its own index -- otherwise
    ' overriding the first series would silently recolour the second.
    over = {}
    over["south"] = "#ff0000"
    pal = gdash_theme.palette_for(loaded.theme, ["north", "south", "east"], over)
    s = gdash_test.eq(s, join(pal, ","), "#111111,#ff0000,#222222", "an override takes its slot; the rest advance through the theme")
    s = gdash_test.eq(s, join(gdash_theme.palette_for(loaded.theme, ["north"], unknown), ","), "#111111,#222222", "no override leaves the theme palette alone")
    junk = {}
    junk["south"] = "crimson"
    s = gdash_test.eq(s, join(gdash_theme.palette_for(loaded.theme, ["north", "south"], junk), ","), "#111111,#222222", "an unusable colour falls back rather than reaching the markup")

    ' --- and it reaches the SVG -------------------------------------------
    rows = [ { m: 1, r: "north", amt: 10.0 }, { m: 1, r: "south", amt: 5.0 },
             { m: 2, r: "north", amt: 40.0 }, { m: 2, r: "south", amt: 20.0 } ]
    v = { dataset: "d", sql: "x", encoding: { mark: "line", x: "m", y: "amt", series: "r" } }
    plain = gdash_render.render_visual("v", v, rows, "", {}, gdash_theme.default_theme())
    themed = gdash_render.render_visual("v", v, rows, "", {}, loaded.theme)
    s = gdash_test.contains_text(s, themed, "#111111", "the theme's first colour is drawn with")
    s = gdash_test.ok(s, not contains(plain, "#111111"), "and is absent without the theme")

    red = {}
    red["south"] = "#ff0000"
    vc = { dataset: "d", sql: "x", encoding: { mark: "line", x: "m", y: "amt", series: "r", colors: red } }
    overridden = gdash_render.render_visual("v", vc, rows, "", {}, loaded.theme)
    s = gdash_test.contains_text(s, overridden, "#ff0000", "a record's override reaches the markup")
    s = gdash_test.ok(s, not contains(themed, "#ff0000"), "and is absent without it")

    ' --- malformed themes fail SAFE, not closed ---------------------------
    '
    ' The opposite ruling from users.json, deliberately: a file gdash cannot
    ' read there is a locked door quietly removed, so it fails closed. Here it
    ' is a palette. Refusing to serve a dashboard over its colours would be a
    ' worse failure than serving it in the wrong ones.
    write(tf, "{ not json at all")
    broken = gdash_theme.load_theme(p)
    s = gdash_test.ok(s, not broken.ok, "a malformed theme reports an error")
    s = gdash_test.eq(s, count(gdash_theme.options_for(broken.theme)), 0, "and yields the defaults rather than raising")

    write(tf, encode({ format: 1, palette: ["#111111", "not-a-colour"] }))
    s = gdash_test.contains_text(s, join(gdash_theme.load_theme(p).errors, "|"), "palette entry 1", "a bad palette entry is named by position")
    write(tf, encode({ format: 2, palette: ["#111111"] }))
    s = gdash_test.contains_text(s, join(gdash_theme.load_theme(p).errors, "|"), "unsupported theme format", "an unknown format is refused")
    write(tf, encode({ format: 1, font_size: 400 }))
    s = gdash_test.contains_text(s, join(gdash_theme.load_theme(p).errors, "|"), "font_size", "an absurd font size is refused")
    write(tf, encode({ format: 1, palette: [] }))
    s = gdash_test.contains_text(s, join(gdash_theme.load_theme(p).errors, "|"), "leave it out", "an empty palette says what to do instead")
    write(tf, encode({ format: 1, palette: "red" }))
    s = gdash_test.contains_text(s, join(gdash_theme.load_theme(p).errors, "|"), "must be an array", "a palette that is not a list is refused")
    s = gdash_test.contains_text(s, join(gdash_theme.check_theme("nope"), "|"), "must be a JSON object", "and a theme that is not an object at all")

    exit(gdash_test.report(s))
end program
