program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_sql from "../src/gdash_sql.bas"

    s = gdash_test.suite("sql")
    q = chr(34)

    ' --- the happy path: bindings are found and rewritten positionally ---
    r = gdash_sql.scan("select a from t where x = :region and y = :region and z = :cut")
    s = gdash_test.eq(s, string(r.names), string(["region", "cut"]), "unique names in first-appearance order")
    s = gdash_test.eq(s, string(r.order), string(["region", "region", "cut"]), "one entry per ? left to right")
    s = gdash_test.eq(s, r.sql, "select a from t where x = ? and y = ? and z = ?", "rewritten to positional")

    ' A repeated binding must expand to one ? per occurrence, or the argument
    ' array silently misaligns with the placeholders.
    vals = { region: "west", cut: 10 }
    s = gdash_test.eq(s, string(gdash_sql.args_for(r, vals)), string(["west", "west", 10]), "args follow ? order, repeats included")

    ' --- adverse: a binding-shaped run of text that is NOT a binding (F2) ---
    lit = "select ':region' as a, x from t where y = :real"
    r2 = gdash_sql.scan(lit)
    s = gdash_test.eq(s, string(r2.names), string(["real"]), "no binding inside a single-quoted literal")
    s = gdash_test.eq(s, r2.sql, "select ':region' as a, x from t where y = ?", "literal text preserved verbatim")

    qi = "select " + q + ":notabinding" + q + " from t where y = :real"
    r3 = gdash_sql.scan(qi)
    s = gdash_test.eq(s, string(r3.names), string(["real"]), "no binding inside a quoted identifier")

    lc = "select a -- :nope" + chr(10) + "from t where y = :real"
    r4 = gdash_sql.scan(lc)
    s = gdash_test.eq(s, string(r4.names), string(["real"]), "no binding inside a line comment")
    s = gdash_test.contains_text(s, r4.sql, "-- :nope", "line comment text preserved")

    bc = "select a /* :nope and :alsonope */ from t where y = :real"
    r5 = gdash_sql.scan(bc)
    s = gdash_test.eq(s, string(r5.names), string(["real"]), "no binding inside a block comment")
    s = gdash_test.contains_text(s, r5.sql, "/* :nope and :alsonope */", "block comment text preserved")

    ' A doubled quote escapes rather than closing the literal, so a binding
    ' after it is still inside the string.
    esc = "select 'it''s :nope' as a from t where y = :real"
    r6 = gdash_sql.scan(esc)
    s = gdash_test.eq(s, string(r6.names), string(["real"]), "doubled quote does not end the literal")
    s = gdash_test.contains_text(s, r6.sql, "'it''s :nope'", "escaped literal preserved")

    ' A cast is not a binding.
    r7 = gdash_sql.scan("select x::text from t where y = :real")
    s = gdash_test.eq(s, string(r7.names), string(["real"]), ":: is a cast, not a binding")
    s = gdash_test.contains_text(s, r7.sql, "x::text", "cast preserved")

    ' A bare colon followed by a non-identifier is left alone.
    r8 = gdash_sql.scan("select a from t where b = ' ' and c = :real")
    s = gdash_test.eq(s, string(r8.names), string(["real"]), "bare colon tolerated")

    ' No bindings at all -- a dataset query's normal shape.
    r9 = gdash_sql.scan("select id, amount from orders")
    s = gdash_test.eq(s, count(r9.names), 0, "no bindings found")
    s = gdash_test.eq(s, r9.sql, "select id, amount from orders", "unbound sql passes through unchanged")

    ' --- identifier legality (design §2: dataset names become table names) ---
    s = gdash_test.ok(s, gdash_sql.legal_identifier("orders"), "plain name legal")
    s = gdash_test.ok(s, gdash_sql.legal_identifier("_o2"), "underscore and digits legal")
    s = gdash_test.ok(s, not gdash_sql.legal_identifier("2orders"), "leading digit illegal")
    s = gdash_test.ok(s, not gdash_sql.legal_identifier("order s"), "space illegal")
    s = gdash_test.ok(s, not gdash_sql.legal_identifier("orders;drop"), "punctuation illegal")
    s = gdash_test.ok(s, not gdash_sql.legal_identifier(""), "empty illegal")

    exit(gdash_test.report(s))
end program
