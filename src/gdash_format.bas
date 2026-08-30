' gdash — the format map.
'
' A format name maps a result column to display text. Consulted by the scalar
' marks and by the `table` mark, which is why it is its own module rather than
' living in either.
'
' `currency` DELEGATES to the platform money type. gBASIC money is an exact
' int64 at the currency's storage scale (exponent + 4 guard digits), it parses
' decimal text digit by digit with no double on the path, and money.text reads
' it back exactly. GDASH-0 hand-rolled this because the type had no exact
' constructor (finding F5); it does now, so the string surgery is gone rather
' than kept beside it.
'
' The F1 text boundary is unchanged by that: minor units still cross from
' SQLite as decimal TEXT and go straight into the currency modifier. No
' number() appears anywhere on this path.

library gdash_format

    function _fmt_digits(s)
        if s = "" then
            return false
        end if
        i = 0
        while i < len(s)
            if not contains("0123456789", mid(s, i, 1)) then
                return false
            end if
            i += 1
        end while
        return true
    end function

    ' Minor units (exact text) -> decimal text at `scale`. String surgery, so
    ' it stays exact past 2^53 -- dividing here would be a double hop.
    function minor_to_decimal(minor_text, scale)
        t = trim(string(minor_text))
        neg = false
        if starts_with(t, "-") then
            neg = true
            t = mid(t, 1, len(t) - 1)
        end if
        while len(t) <= scale
            t = "0" + t
        end while
        if scale = 0 then
            out = t
        else
            out = mid(t, 0, len(t) - scale) + "." + mid(t, len(t) - scale, scale)
        end if
        if neg then
            out = "-" + out
        end if
        return out
    end function

    ' Build a money value from exact decimal text. The currency modifier is a
    ' literal in the source, so the supported set is enumerated here; an
    ' unknown code is a refusal rather than a silent fallback to USD, because
    ' rendering yen as dollars is worse than saying no.
    function to_money(decimal_text, currency)
        on error goto next
        if currency = "USD" then
            m{USD}= decimal_text
        else if currency = "EUR" then
            m{EUR}= decimal_text
        else if currency = "GBP" then
            m{GBP}= decimal_text
        else if currency = "JPY" then
            m{JPY}= decimal_text
        else if currency = "CHF" then
            m{CHF}= decimal_text
        else if currency = "CAD" then
            m{CAD}= decimal_text
        else if currency = "AUD" then
            m{AUD}= decimal_text
        else if currency = "KWD" then
            m{KWD}= decimal_text
        else
            return { ok: false, value: 0, message: "unsupported currency '" + string(currency) + "'" }
        end if
        if error then
            ' Range is the interesting failure, and it is a consequence of
            ' the guard digits: an int64 at storage scale exponent+4 tops out
            ' far below an int64 at the minor unit. USD reaches
            ' $9,223,372,036,854.77, not $92 quadrillion. gdash's SQLite
            ' storage is unaffected -- only rendering is bounded -- and a
            ' refusal is better than a second formatting path with different
            ' rounding semantics quietly taking over above a threshold.
            if contains(error.message, "out of range") then
                return { ok: false, value: 0, message: "value is beyond what " + string(currency) + " can represent (guard digits bound it near 9.2 trillion); the data is intact, only rendering refuses" }
            end if
            return { ok: false, value: 0, message: error.message }
        end if
        return { ok: true, value: m, message: "" }
    end function

    function supported_currencies()
        return ["USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "KWD"]
    end function

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

    function _symbol(currency)
        if currency = "USD" then
            return "$"
        end if
        if currency = "EUR" then
            return chr(226) + chr(130) + chr(172)
        end if
        if currency = "GBP" then
            return chr(194) + chr(163)
        end if
        if currency = "JPY" then
            return chr(194) + chr(165)
        end if
        return currency + " "
    end function

    ' Render minor units as currency. The money type does the arithmetic and
    ' the minor-unit rounding; grouping is applied to the digits it returns.
    function currency(minor_text, scale, code)
        dec = minor_to_decimal(minor_text, scale)
        built = to_money(dec, code)
        if not built.ok then
            return { ok: false, text: "", message: built.message }
        end if
        ' money.text at the currency's own minor-unit precision -- the exact
        ' exit the platform added for this.
        shown = money.text(built.value, minor_places(code))
        neg = false
        if starts_with(shown, "-") then
            neg = true
            shown = mid(shown, 1, len(shown) - 1)
        end if
        bits = split(shown, ".")
        body = _symbol(code) + _group(bits[0])
        if count(bits) = 2 then
            body = body + "." + bits[1]
        end if
        if neg then
            body = "-" + body
        end if
        return { ok: true, text: body, message: "" }
    end function

    ' The currency's own minor-unit exponent -- what a human is shown, as
    ' distinct from the storage scale that carries the guard digits.
    function minor_places(code)
        if code = "JPY" then
            return 0
        end if
        if code = "KWD" then
            return 3
        end if
        return 2
    end function

    function number_fmt(value, decimals)
        on error goto next
        r = round(number(string(value)), decimals)
        if error then
            return string(value)
        end if
        t = string(r)
        neg = false
        if starts_with(t, "-") then
            neg = true
            t = mid(t, 1, len(t) - 1)
        end if
        bits = split(t, ".")
        frac = ""
        if count(bits) = 2 then
            frac = bits[1]
        end if
        while len(frac) < decimals
            frac = frac + "0"
        end while
        out = _group(bits[0])
        if decimals > 0 then
            out = out + "." + frac
        end if
        if neg then
            out = "-" + out
        end if
        return out
    end function

    function percent_fmt(value, decimals)
        on error goto next
        n = number(string(value)) * 100
        if error then
            return string(value)
        end if
        return number_fmt(n, decimals) + "%"
    end function

    function known(name)
        return contains(["currency", "number", "percent", "text"], name)
    end function

    ' Apply a format spec to one cell. `spec` is a record: { name, decimals,
    ' currency, scale }. Returns display text.
    function apply(spec, raw, exact_text)
        nm = default(spec["name"], "text")
        if nm = "currency" then
            src = exact_text
            if is_unknown(src) or is_nothing(src) then
                src = string(raw)
            end if
            got = currency(src, default(spec["scale"], 2), default(spec["currency"], "USD"))
            if not got.ok then
                return "!" + got.message
            end if
            return got.text
        end if
        if nm = "number" then
            return number_fmt(raw, default(spec["decimals"], 0))
        end if
        if nm = "percent" then
            return percent_fmt(raw, default(spec["decimals"], 1))
        end if
        return string(raw)
    end function

end library
