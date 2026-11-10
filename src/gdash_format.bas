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
' Every currency ISO 4217 defines is supported. GDASH-1 shipped eight, because
' `{USD}=` needs a LITERAL currency code and each supported one was therefore
' an explicit branch; its DONE note called widening "mechanical, wanting
' generation rather than typing". `money.of(code, text)` takes the code as a
' value, so it now wants neither.
'
' Since GDASH-20 a money column ARRIVES as money: G-SQL stores gBASIC values,
' with their currency, so there is no minor-unit text to reassemble. A money
' value is rendered at the column's display scale, rounded half-even
' (gsql_migration_plan.md D4a), and nothing on the path is a double.

library gdash_format

    ' A stored epoch as something a person reads. Lives here rather than in
    ' gdash_app because the CLI's `list` needs the same answer, and two
    ' renderings of "how old is this data" that could drift apart is exactly
    ' the kind of small inconsistency that makes a status line untrustworthy.
    '
    ' 0 is "never", not 1970: every caller stores 0 for "has not happened".
    function when(at)
        if at = 0 then
            return "never"
        end if
        on error goto next
        t = to_zone(from_epoch(at), "local")
        if error then
            ' Unformattable is still information -- better the raw number than
            ' a blank where a timestamp should be.
            return string(at)
        end if
        return string(t)
    end function

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

    ' The int64 an exact money value is, spelled out. Used only to say what a
    ' currency's range actually is when a value exceeds it.
    function _int64_max()
        return "9223372036854775807"
    end function

    ' The largest amount a currency can represent, as decimal text. Storage is
    ' an int64 at exponent + 4 guard digits, so the bound moves with the
    ' currency: USD stops near 9.2 trillion and JPY near 922 trillion. String
    ' surgery, because computing it would be the 2^53 hop this module exists
    ' to avoid.
    function range_ceiling(code)
        exp = minor_places(code)
        if exp < 0 then
            return ""
        end if
        digits = _int64_max()
        cut = len(digits) - (exp + 4)
        whole = mid(digits, 0, cut)
        frac = mid(digits, cut, exp)
        if exp = 0 then
            return _group(whole)
        end if
        return _group(whole) + "." + frac
    end function

    ' Build a money value from exact decimal text. The code is a VALUE, not a
    ' literal, which is what lets every ISO 4217 currency work rather than the
    ' eight that could be spelled out as branches.
    function to_money(decimal_text, currency)
        on error goto next
        m = money.of(currency, decimal_text)
        if error then
            msg = error.message
            ' Range is the interesting failure, and it is a consequence of
            ' the guard digits: an int64 at storage scale exponent+4 tops out
            ' far below an int64 at the minor unit. Since GDASH-20 the store
            ' holds the same type, so a stored value cannot exceed it; this is
            ' reached by a plain number, and a refusal is better than a second
            ' formatting path with different rounding semantics.
            if contains(msg, "out of range") then
                return { ok: false, value: 0, message: "value is beyond what " + string(currency) + " can represent (its exact range stops at " + range_ceiling(currency) + "); the data is intact, only rendering refuses" }
            end if
            if contains(msg, "not a known currency") then
                return { ok: false, value: 0, message: "unsupported currency '" + string(currency) + "'" }
            end if
            return { ok: false, value: 0, message: msg }
        end if
        return { ok: true, value: m, message: "" }
    end function

    ' Every code ISO 4217 defines, from the platform rather than from a list
    ' here that would drift out of date the first time a currency redenominated.
    function supported_currencies()
        out = []
        for each c in money.currencies()
            out = concat(out, [c.code])
        next
        return out
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

    ' CODEPOINTS, NOT UTF-8 BYTES. These were written as `chr(194) + chr(165)`
    ' -- the two bytes of the yen sign handed to a function that takes
    ' codepoints, so `chr(194)` produced `Â` and every JPY figure gdash ever
    ' rendered read `Â¥1,234`. Same for `£` and `€`. Thirteen phases, invisible,
    ' because `$` is ASCII and the fixtures were all dollars (G13-1).
    '
    ' Written as literal characters rather than `chr()` so that what is here is
    ' the answer and not a recipe. Each is one codepoint, which the suite asserts
    ' with `len` -- the check that would have caught this the first time.
    function _symbol(currency)
        if currency = "USD" then
            return "$"
        end if
        if currency = "EUR" then
            return "€"
        end if
        if currency = "GBP" then
            return "£"
        end if
        if currency = "JPY" then
            return "¥"
        end if
        ' Every other ISO 4217 code renders as `CHF 1,234.00`, which is correct
        ' and unambiguous, and is why this phase adds no further symbols.
        return currency + " "
    end function

    ' A plain number or decimal text as exact decimal text, for `money.of`.
    ' An integer is spelled exactly; a fraction is rounded to six places
    ' first, because a double's shortest spelling can carry seventeen digits
    ' and money text refuses more decimals than its currency stores.
    function _decimal_text(value)
        if type(value) = "string" then
            return trim(value)
        end if
        if type(value) = "number" and value != floor(value) then
            return string(round(value, 6))
        end if
        return string(value)
    end function

    ' Render a value as currency at `places` decimals, rounded half-even.
    '
    ' A MONEY VALUE CARRIES ITS OWN CURRENCY, and that is the one it renders
    ' in. `code` is what the record states, or "" when it states nothing; a
    ' stated currency that disagrees with the value is REFUSED, not relabelled
    ' -- "¥430,000" drawn with a dollar sign is the plausible wrong answer the
    ' whole money design exists to prevent. A plain number (`count(*)`, or a
    ' source that sent no money) is an amount in `code`, USD when unstated.
    function currency(value, places, code)
        cur = string(default(code, ""))
        if type(value) = "money" then
            own = money.currency(value)
            if cur != "" and cur != own then
                return { ok: false, text: "", message: "the value is " + own + ", and the visual formats it as " + cur }
            end if
            cur = own
            m = value
        else
            if cur = "" then
                cur = "USD"
            end if
            built = to_money(_decimal_text(value), cur)
            if not built.ok then
                return { ok: false, text: "", message: built.message }
            end if
            m = built.value
        end if
        shown = money.text(m, places)
        neg = false
        if starts_with(shown, "-") then
            neg = true
            shown = mid(shown, 1, len(shown) - 1)
        end if
        bits = split(shown, ".")
        body = _symbol(cur) + _group(bits[0])
        if count(bits) = 2 then
            body = body + "." + bits[1]
        end if
        if neg then
            body = "-" + body
        end if
        return { ok: true, text: body, message: "" }
    end function

    ' The currency's own minor-unit exponent -- what a human is shown, as
    ' distinct from the storage scale that carries the guard digits. -1 for a
    ' code ISO 4217 does not define, which `to_money` refuses before this is
    ' consulted for anything that renders.
    '
    ' `money.currencies()` builds all 178 records per call, which measures at
    ' ~80us. That is per formatted VALUE, so a hundred-row table pays ~8ms and
    ' a ten-thousand-row one pays most of a second -- worth knowing before
    ' someone renders a table that large, and cheap enough not to restructure
    ' the format API around today (finding G4-13).
    ' The symbol, for callers outside this module. `_symbol` stays internal
    ' because it is one branch of the money formatter; this is the accessor,
    ' and it exists so the chart axis can be DERIVED from the record's
    ' `currency` rather than declared a second time (GDASH-10 §2.2).
    function symbol_for(code)
        return _symbol(code)
    end function

    ' Decimal places a currency STORES: its minor unit plus four guard digits
    ' (USD 6, JPY 4). The most a money column can show; -1 for a code ISO
    ' 4217 does not define.
    function storage_places(code)
        mp = minor_places(code)
        if mp < 0 then
            return -1
        end if
        return mp + 4
    end function

    function minor_places(code)
        for each c in money.currencies()
            if c.code = code then
                return c.exponent
            end if
        next
        return -1
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

    ' A value as a number for chart GEOMETRY. A bar's height is pixels, so a
    ' double is right here -- and only here: every value a person reads goes
    ' through `currency`. Money is read at its full storage scale, so the
    ' bar is not drawn at a rounded height.
    function chart_number(value)
        if is_unknown(value) or is_nothing(value) then
            return unknown
        end if
        if type(value) = "money" then
            return number(money.text(value))
        end if
        return number(value)
    end function

    ' Apply a format spec to one cell. `spec` is a record: { name, decimals,
    ' currency, scale }. Returns display text.
    function apply(spec, raw)
        nm = default(spec["name"], "text")
        if nm = "currency" then
            if is_unknown(raw) or is_nothing(raw) then
                return ""
            end if
            got = currency(raw, default(spec["scale"], 2), default(spec["currency"], ""))
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
