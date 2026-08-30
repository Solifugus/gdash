program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_format from "../src/gdash_format.bas"

    s = gdash_test.suite("format")

    ' --- minor units -> decimal text, exact at every magnitude (F1) ---
    s = gdash_test.eq(s, gdash_format.minor_to_decimal("325100", 2), "3251.00", "scale 2")
    s = gdash_test.eq(s, gdash_format.minor_to_decimal("1", 2), "0.01", "one cent")
    s = gdash_test.eq(s, gdash_format.minor_to_decimal("-125075", 2), "-1250.75", "negative")
    s = gdash_test.eq(s, gdash_format.minor_to_decimal("9007199254740993", 2), "90071992547409.93", "past 2^53")
    s = gdash_test.eq(s, gdash_format.minor_to_decimal("1234", 0), "1234", "scale 0")

    ' --- currency, delegated to the platform money type ---
    c = gdash_format.currency("325100", 2, "USD")
    s = gdash_test.ok(s, c.ok, "currency renders")
    s = gdash_test.eq(s, c.text, "$3,251.00", "grouped USD")
    s = gdash_test.eq(s, gdash_format.currency("1", 2, "USD").text, "$0.01", "one cent")
    s = gdash_test.eq(s, gdash_format.currency("-125075", 2, "USD").text, "-$1,250.75", "negative USD")

    ' JPY has no minor unit: it must not render two decimals.
    s = gdash_test.eq(s, gdash_format.currency("1234", 0, "JPY").text, chr(194) + chr(165) + "1,234", "JPY at exponent 0")
    ' KWD carries three.
    s = gdash_test.eq(s, gdash_format.currency("1234567", 3, "KWD").text, "KWD 1,234.567", "KWD at exponent 3")

    ' Exact well past 2^53 -- the money type is int64 at storage scale, and
    ' the text boundary means no double appears on the path. 2^53 minor units
    ' is ~$90tn, which is ABOVE what USD can now represent, so the exactness
    ' assertion sits just under the ceiling instead.
    s = gdash_test.eq(s, gdash_format.currency("92233720368", 2, "USD").text, "$922,337,203.68", "exact well past 2^53 units")
    s = gdash_test.eq(s, gdash_format.currency("922337203685477", 2, "USD").text, "$9,223,372,036,854.77", "exact at the USD ceiling")

    ' Above the ceiling gdash REFUSES rather than falling back to a second
    ' formatting path. Guard digits cost 10,000x of range: an int64 at
    ' storage scale (exponent+4) tops out near $9.2tn, not $92 quadrillion.
    ' The stored data is untouched; only rendering declines.
    over_range = gdash_format.currency("922337203685478", 2, "USD")
    s = gdash_test.ok(s, not over_range.ok, "beyond the currency range is refused")
    s = gdash_test.contains_text(s, over_range.message, "data is intact", "refusal distinguishes rendering from storage")

    ' An unknown currency is refused, not silently rendered as dollars.
    bad = gdash_format.currency("100", 2, "XYZ")
    s = gdash_test.ok(s, not bad.ok, "unknown currency refused")
    s = gdash_test.contains_text(s, bad.message, "unsupported currency", "and says so")

    ' --- RETENTION, not display ---
    ' The platform session's warning: an exactly-stored sub-minor-unit value
    ' and one rounded at the door RENDER IDENTICALLY, so asserting the
    ' displayed form passes on both. Only arithmetic separates them.
    m = gdash_format.to_money("0.10432", "USD")
    s = gdash_test.ok(s, m.ok, "sub-cent authored value accepted")
    s = gdash_test.eq(s, string(m.value), "0.10", "it displays rounded, as expected")
    s = gdash_test.eq(s, string(m.value * 1000), "104.32", "but it was STORED exactly -- x1000 proves it")
    ' Guard digits are retained across a multi-step calculation.
    p = gdash_format.to_money("0.07", "USD")
    s = gdash_test.eq(s, string(p.value * 1.5), "0.10", "0.07*1.5 rounds half-even at display")
    s = gdash_test.eq(s, string(p.value * 1.5 * 200), "21.00", "and the guard digits survived to be multiplied")

    ' Digits beyond the storage scale are rejected, not rounded.
    over = gdash_format.to_money("0.0300004", "USD")
    s = gdash_test.ok(s, not over.ok, "7 decimals refused for USD (storage scale 6)")
    ok6 = gdash_format.to_money("0.030000", "USD")
    s = gdash_test.ok(s, ok6.ok, "6 decimals accepted for USD")

    ' --- number and percent ---
    s = gdash_test.eq(s, gdash_format.number_fmt(1234567, 0), "1,234,567", "grouped integer")
    s = gdash_test.eq(s, gdash_format.number_fmt(1234.5, 2), "1,234.50", "padded decimals")
    s = gdash_test.eq(s, gdash_format.number_fmt(-42, 0), "-42", "negative")
    s = gdash_test.eq(s, gdash_format.percent_fmt(0.125, 1), "12.5%", "percent")

    ' --- the dispatcher ---
    s = gdash_test.ok(s, gdash_format.known("currency"), "currency is a known format")
    s = gdash_test.ok(s, not gdash_format.known("sparkline"), "unknown format is not known")
    s = gdash_test.eq(s, gdash_format.apply({ name: "currency", scale: 2, currency: "USD" }, 0, "325100"), "$3,251.00", "apply currency uses the exact text")
    s = gdash_test.eq(s, gdash_format.apply({ name: "number", decimals: 1 }, 12.34, unknown), "12.3", "apply number")
    s = gdash_test.eq(s, gdash_format.apply({ name: "text" }, "west", unknown), "west", "apply text")

    exit(gdash_test.report(s))
end program
