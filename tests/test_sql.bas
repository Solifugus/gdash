program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_sql from "../src/gdash_sql.bas"

    s = gdash_test.suite("sql")
    q = chr(34)

    ' --- the happy path: bindings are found and rewritten positionally ---
    r = gdash_sql.scan("select a from t where x = :region and y = :region and z = :cut")
    s = gdash_test.eq(s, string(r.names), string(["region", "cut"]), "unique names in first-appearance order")
    s = gdash_test.eq(s, string(r.order), string(["region", "region", "cut"]), "one entry per ? left to right")
    s = gdash_test.eq(s, r.sql, "select a from t where x = $1 and y = $2 and z = $3", "rewritten to G-SQL positional parameters")

    ' A repeated binding must expand to one ? per occurrence, or the argument
    ' array silently misaligns with the placeholders.
    vals = { region: "west", cut: 10 }
    s = gdash_test.eq(s, string(gdash_sql.args_for(r, vals)), string(["west", "west", 10]), "args follow ? order, repeats included")

    ' --- adverse: a binding-shaped run of text that is NOT a binding (F2) ---
    lit = "select ':region' as a, x from t where y = :real"
    r2 = gdash_sql.scan(lit)
    s = gdash_test.eq(s, string(r2.names), string(["real"]), "no binding inside a single-quoted literal")
    s = gdash_test.eq(s, r2.sql, "select ':region' as a, x from t where y = $1", "literal text preserved verbatim")

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

    ' --- adversarial (GDASH-6 §2.6) --------------------------------------
    '
    ' The scanner is the older of gdash's two text surfaces and never got the
    ' attention LDAP escaping got in GDASH-5, because no directory made the
    ' risk vivid. Everything below is malformed, hostile or degenerate input.
    ' The bar is: refuse or pass through, never crash and never silently
    ' corrupt.

    ' Unterminated constructs. A query can arrive half-written from an author
    ' editing a record; the scanner must not spin or crash on one.
    open_str = gdash_sql.scan("select a from t where b = 'unterminated :nope")
    s = gdash_test.eq(s, count(open_str.names), 0, "a binding inside an unterminated literal is not a binding")
    s = gdash_test.contains_text(s, open_str.sql, "unterminated :nope", "and the text survives the scan")

    open_com = gdash_sql.scan("select a from t /* unterminated :nope")
    s = gdash_test.eq(s, count(open_com.names), 0, "nor is one inside an unterminated block comment")

    open_dq = gdash_sql.scan("select " + chr(34) + "col :nope from t")
    s = gdash_test.eq(s, count(open_dq.names), 0, "nor inside an unterminated quoted identifier")

    ' Degenerate inputs.
    s = gdash_test.eq(s, count(gdash_sql.scan("").names), 0, "an empty query binds nothing")
    s = gdash_test.eq(s, gdash_sql.scan("").sql, "", "and rewrites to nothing")
    s = gdash_test.eq(s, count(gdash_sql.scan(":").names), 0, "a lone colon is not a binding")
    s = gdash_test.eq(s, gdash_sql.scan(":").sql, ":", "and is passed through")
    s = gdash_test.eq(s, count(gdash_sql.scan("::").names), 0, "a lone cast is not a binding")

    ' A binding at the very end, with nothing after it to stop the scan.
    tail_bind = gdash_sql.scan("select a from t where b = :region")
    s = gdash_test.eq(s, join(tail_bind.names, ","), "region", "a binding at end of text is found")
    s = gdash_test.eq(s, tail_bind.sql, "select a from t where b = $1", "and rewritten")

    ' Adjacent and repeated bindings: `names` is unique in first-appearance
    ' order, `order` is one entry per '?', and the two must not be confused --
    ' args_for reads `order`, and a query binding one param three times needs
    ' three arguments.
    rep = gdash_sql.scan("select a from t where b = :r or c = :r or d = :other and e = :r")
    s = gdash_test.eq(s, join(rep.names, ","), "r,other", "repeated bindings appear once in names")
    s = gdash_test.eq(s, join(rep.order, ","), "r,r,other,r", "and once per placeholder in order")
    vals = {}
    vals["r"] = "one"
    vals["other"] = "two"
    s = gdash_test.eq(s, join(gdash_sql.args_for(rep, vals), ","), "one,one,two,one", "so the argument array matches the placeholders")

    ' A NUL in the query text. gBASIC strings are binary-safe (and since
    ' 36cb538 so are the string builtins), so this must not truncate.
    nul_sql = gdash_sql.scan("select a" + chr(0) + "b from t where c = :real")
    s = gdash_test.eq(s, join(nul_sql.names, ","), "real", "a NUL in the query does not hide a later binding")
    ' Asserted as "the byte is still there", not as a character count: a
    ' length is a number somebody has to get right by hand, and I got it wrong
    ' the first time in a way that looked like a defect in the scanner.
    s = gdash_test.eq(s, code(mid(nul_sql.sql, 8, 1)), 0, "and the NUL itself survives the rewrite")
    s = gdash_test.contains_text(s, nul_sql.sql, "b from t where c = $1", "with everything after it intact")

    ' A long identifier: bounded by the scanner, not by a buffer.
    long_name = "a234567890123456789012345678901234567890123456789012345678901234"
    long_bind = gdash_sql.scan("select x from t where y = :" + long_name)
    s = gdash_test.eq(s, join(long_bind.names, ","), long_name, "a 64-character binding name is read whole")

    ' Non-ASCII stops an identifier rather than entering it, so a binding name
    ' can never contain something a record could not declare.
    uni = gdash_sql.scan("select x from t where y = :re" + chr(233) + "gion")
    s = gdash_test.eq(s, join(uni.names, ","), "re", "an identifier stops at the first non-ASCII character")

    ' A LITERAL '?' ALREADY IN THE QUERY. The scanner rewrites :name to ?, so
    ' an author who writes their own ? shifts every argument after it. gdash
    ' owns the rewrite (finding F2), which makes this gdash's problem to know
    ' about even though sqlite is the one that would bind wrongly.
    mixed = gdash_sql.scan("select a from t where b = ? and c = :region")
    s = gdash_test.eq(s, join(mixed.order, ","), "region", "a hand-written ? contributes nothing to the order")
    s = gdash_test.eq(s, mixed.sql, "select a from t where b = ? and c = $1", "yet survives into the rewritten sql")
    ' ...so args_for supplies ONE argument for TWO placeholders. Recorded as a
    ' known edge rather than papered over: a record's SQL is written by an
    ' author, and this is what happens if they write a placeholder themselves.
    supplied = {}
    supplied["region"] = "west"
    s = gdash_test.eq(s, count(gdash_sql.args_for(mixed, supplied)), 1, "leaving one argument for two placeholders")
    ' ...which is why the record validator refuses it before any database is
    ' contacted (design §1), rather than leaving sqlite to complain about
    ' argument counts at refresh time.
    s = gdash_test.eq(s, gdash_sql.placeholders("select a from t where b = ? and c = :region"), 1, "a hand-written placeholder is counted")
    s = gdash_test.eq(s, gdash_sql.placeholders("select a from t where b = :region"), 0, "one gdash produced is not")
    s = gdash_test.eq(s, gdash_sql.placeholders("select '?' from t"), 0, "nor is one inside a string literal")
    s = gdash_test.eq(s, gdash_sql.placeholders("select a from t -- ?"), 0, "nor one in a comment")
    s = gdash_test.eq(s, gdash_sql.placeholders("select a from t where b = ? or c = ?"), 2, "and two are two")
    ' A hand-written $1 is the worse case under G-SQL: it would silently take
    ' the value of gdash's own first binding. So it is counted too, and the
    ' validator refuses it -- but a dollar sign that is not a parameter is not.
    s = gdash_test.eq(s, gdash_sql.placeholders("select a from t where b = $1 and c = :region"), 1, "a hand-written $1 is counted as a placeholder")
    s = gdash_test.eq(s, gdash_sql.placeholders("select '$1' from t"), 0, "but not inside a string literal")
    s = gdash_test.eq(s, gdash_sql.placeholders("select a$b from t"), 0, "and a dollar sign not followed by a digit is not one")

    ' A parameter with no supplied value yields `unknown` rather than a hole,
    ' so the array length still matches the placeholder count.
    missing = gdash_sql.scan("select a from t where b = :never")
    s = gdash_test.eq(s, count(gdash_sql.args_for(missing, {})), 1, "an unsupplied param still occupies its position")
    s = gdash_test.ok(s, is_unknown(gdash_sql.args_for(missing, {})[0]), "as unknown, not as a missing element")

    ' --- identifiers: everything a dataset name must not be ---------------
    bad_names = ["orders; drop table t", "orders--", "orders/*x*/", "'orders'",
                 chr(34) + "orders" + chr(34), "orders\ttab", "orders name",
                 "", " ", "1", "-", ".", "*", "orders." + "t", "or" + chr(0) + "ders"]
    i = 0
    while i < count(bad_names)
        s = gdash_test.ok(s, not gdash_sql.legal_identifier(bad_names[i]), "refused as an identifier: <" + bad_names[i] + ">")
        i += 1
    end while
    s = gdash_test.ok(s, gdash_sql.legal_identifier("orders_2024"), "and an ordinary name is still legal")

    exit(gdash_test.report(s))
end program
