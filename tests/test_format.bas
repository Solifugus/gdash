program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_format from "../src/gdash_format.bas"

    s = gdash_test.suite("format")

    ' --- currency, delegated to the platform money type ---
    ' An AMOUNT, not minor units (GDASH-20): money arrives as money, and a
    ' plain number or decimal text is an amount in the stated currency.
    c = gdash_format.currency("3251.00", 2, "USD")
    s = gdash_test.ok(s, c.ok, "currency renders")
    s = gdash_test.eq(s, c.text, "$3,251.00", "grouped USD")
    s = gdash_test.eq(s, gdash_format.currency("0.01", 2, "USD").text, "$0.01", "one cent")
    s = gdash_test.eq(s, gdash_format.currency("-1250.75", 2, "USD").text, "-$1,250.75", "negative USD")

    ' JPY has no minor unit: it must not render two decimals.
    '
    ' THIS ASSERTION USED TO ENCODE THE BUG. It expected
    ' `chr(194) + chr(165)` -- which is what the implementation produced, and
    ' it produced it because someone wrote the UTF-8 BYTES of the yen sign into
    ' a function that takes CODEPOINTS. The test was written from the code
    ' rather than from the answer, so it passed for thirteen phases while every
    ' JPY, GBP and EUR figure gdash rendered came out as `Â¥`, `Â£`, `â‚¬`. USD
    ' is the only currency that could not have shown it, and USD is all the
    ' fixtures had.
    '
    ' The expected values below are written as LITERAL CHARACTERS, not as
    ' chr() arithmetic, precisely so that the next person reads the answer
    ' rather than a recipe. A symbol is one codepoint: len is the assertion
    ' that says so.
    s = gdash_test.eq(s, gdash_format.currency("1234", 0, "JPY").text, "¥1,234", "JPY at exponent 0")
    s = gdash_test.eq(s, len(gdash_format.symbol_for("JPY")), 1, "the yen sign is ONE character, not its two UTF-8 bytes")
    s = gdash_test.eq(s, gdash_format.currency("1250.75", 2, "GBP").text, "£1,250.75", "GBP")
    s = gdash_test.eq(s, len(gdash_format.symbol_for("GBP")), 1, "and the pound sign is one character")
    s = gdash_test.eq(s, gdash_format.currency("1250.75", 2, "EUR").text, "€1,250.75", "EUR")
    s = gdash_test.eq(s, len(gdash_format.symbol_for("EUR")), 1, "and the euro sign is one character")
    s = gdash_test.eq(s, gdash_format.currency("-430000", 0, "JPY").text, "-¥430,000", "a negative zero-decimal currency")
    s = gdash_test.eq(s, gdash_format.symbol_for("USD"), "$", "USD is ASCII, which is why nothing caught the others")
    ' KWD carries three.
    s = gdash_test.eq(s, gdash_format.currency("1234.567", 3, "KWD").text, "KWD 1,234.567", "KWD at exponent 3")

    ' Exact at magnitude -- the money type is int64 at storage scale, and no
    ' double appears on the path.
    s = gdash_test.eq(s, gdash_format.currency("922337203.68", 2, "USD").text, "$922,337,203.68", "exact at magnitude")
    s = gdash_test.eq(s, gdash_format.currency("9223372036854.77", 2, "USD").text, "$9,223,372,036,854.77", "exact at the USD ceiling")

    ' Above the ceiling gdash REFUSES rather than falling back to a second
    ' formatting path. Guard digits cost 10,000x of range: an int64 at
    ' storage scale (exponent+4) tops out near $9.2tn, not $92 quadrillion.
    ' The stored data is untouched; only rendering declines.
    over_range = gdash_format.currency("9223372036854.78", 2, "USD")
    s = gdash_test.ok(s, not over_range.ok, "beyond the currency range is refused")
    s = gdash_test.contains_text(s, over_range.message, "data is intact", "refusal distinguishes rendering from storage")

    ' An unknown currency is refused, not silently rendered as dollars.
    bad = gdash_format.currency("1.00", 2, "XYZ")
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
    usd {USD}= "3251.00"
    s = gdash_test.eq(s, gdash_format.apply({ name: "currency", scale: 2, currency: "USD" }, usd), "$3,251.00", "apply currency renders a money value")
    s = gdash_test.eq(s, gdash_format.apply({ name: "number", decimals: 1 }, 12.34), "12.3", "apply number")
    s = gdash_test.eq(s, gdash_format.apply({ name: "text" }, "west"), "west", "apply text")
    s = gdash_test.eq(s, gdash_format.apply({ name: "currency", scale: 2 }, unknown), "", "an absent amount renders as nothing, not as an error")

    ' --- a money value renders in ITS OWN currency (GDASH-20) ---
    yen {JPY}= "430000"
    s = gdash_test.eq(s, gdash_format.currency(yen, 0, "").text, "¥430,000", "money with no stated currency renders in its own")
    s = gdash_test.eq(s, gdash_format.currency(yen, 0, "JPY").text, "¥430,000", "and a stated currency that agrees is fine")
    clash = gdash_format.currency(yen, 0, "USD")
    s = gdash_test.ok(s, not clash.ok, "a stated currency that DISAGREES is refused, not relabelled")
    s = gdash_test.contains_text(s, clash.message, "the value is JPY", "and says what the value is")
    s = gdash_test.eq(s, gdash_format.currency(12, 2, "").text, "$12.00", "a plain number with no currency is dollars")

    ' --- D4a: rounded half-even, only when shown, at the display scale ---
    tie1 {USD}= "1250.745"
    tie2 {USD}= "1250.735"
    s = gdash_test.eq(s, gdash_format.currency(tie1, 2, "").text, "$1,250.74", "a tie goes to the even digit")
    s = gdash_test.eq(s, gdash_format.currency(tie2, 2, "").text, "$1,250.74", "from either side")
    rate {USD}= "0.104320"
    s = gdash_test.eq(s, gdash_format.currency(rate, 4, "").text, "$0.1043", "a scale-4 column shows four places")
    tiny {USD}= "-0.004"
    s = gdash_test.eq(s, gdash_format.currency(tiny, 2, "").text, "$0.00", "a value that rounds to zero carries no minus sign")
    s = gdash_test.eq(s, gdash_format.storage_places("USD"), 6, "USD stores six places")
    s = gdash_test.eq(s, gdash_format.storage_places("JPY"), 4, "JPY stores four")
    s = gdash_test.eq(s, gdash_format.chart_number(rate), 0.10432, "chart geometry reads money at its full scale")
    s = gdash_test.ok(s, is_unknown(gdash_format.chart_number(unknown)), "and an absent value is a gap, not zero")

    ' --- every ISO 4217 currency, not the eight that could be branches ---
    ' GDASH-1 supported eight because {USD}= needs a literal code. money.of
    ' takes it as a value, so the limit is gone rather than widened.
    s = gdash_test.ok(s, count(gdash_format.supported_currencies()) > 150, "the supported set is the platform's, not a list here")
    s = gdash_test.ok(s, contains(gdash_format.supported_currencies(), "NGN"), "a currency GDASH-1 could not render is supported")
    s = gdash_test.ok(s, contains(gdash_format.supported_currencies(), "INR"), "and so is another")

    ' Rendered at their own minor units, from the platform's exponents.
    s = gdash_test.eq(s, gdash_format.minor_places("USD"), 2, "USD shows two places")
    s = gdash_test.eq(s, gdash_format.minor_places("JPY"), 0, "JPY shows none")
    s = gdash_test.eq(s, gdash_format.minor_places("KWD"), 3, "KWD shows three")
    s = gdash_test.eq(s, gdash_format.minor_places("BHD"), 3, "and so does BHD, which was never enumerated here")

    ngn = gdash_format.currency("1234.56", 2, "NGN")
    s = gdash_test.ok(s, ngn.ok, "a previously unsupported currency renders -- " + ngn.message)
    s = gdash_test.eq(s, ngn.text, "NGN 1,234.56", "with grouping and its code, since ISO gives no symbol")

    ' A code ISO 4217 does not define is still a refusal, not a fallback to
    ' dollars: rendering one currency as another is worse than saying no.
    bogus = gdash_format.currency("1.00", 2, "XYZ")
    s = gdash_test.ok(s, not bogus.ok, "an invented currency is refused")
    s = gdash_test.contains_text(s, bogus.message, "unsupported currency", "and says so in gdash's own words")

    ' --- the range refusal names the currency's own limit ---
    ' The bound moves with the exponent, because storage is an int64 at
    ' exponent + 4 guard digits.
    s = gdash_test.eq(s, gdash_format.range_ceiling("USD"), "9,223,372,036,854.77", "USD stops near 9.2 trillion")
    s = gdash_test.eq(s, gdash_format.range_ceiling("JPY"), "922,337,203,685,477", "JPY, with no minor unit, reaches a hundred times further")
    s = gdash_test.eq(s, gdash_format.range_ceiling("KWD"), "922,337,203,685.477", "and KWD, with three, stops sooner")

    ' Ten trillion: past USD's ceiling, inside JPY's.
    over = gdash_format.currency("10000000000000", 2, "USD")
    s = gdash_test.ok(s, not over.ok, "a value past the ceiling is refused")
    s = gdash_test.contains_text(s, over.message, "9,223,372,036,854.77", "naming the limit it passed")
    s = gdash_test.contains_text(s, over.message, "the data is intact", "and saying the data is not the problem")

    ' The same magnitude is fine in JPY, which is the point of naming the
    ' currency rather than quoting one number for all of them.
    s = gdash_test.ok(s, gdash_format.currency("10000000000000", 0, "JPY").ok, "the same magnitude renders in a currency with room for it")

    exit(gdash_test.report(s))
end program
