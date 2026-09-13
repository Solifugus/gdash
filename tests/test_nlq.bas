program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_nlq from "../src/gdash_nlq.bas"

    s = gdash_test.suite("nlq")

    ' The scaled columns a dashboard has, as scaled_columns would report them.
    scaled = {}
    scaled["orders.orders.amount"] = { dataset: "orders", column: "amount", scale: 2, currency: "USD" }

    ' --- the measured failure, restated ------------------------------------
    '
    ' GDASH-12 step 0: this exact query returned 6 where the answer is 2, with
    ' nlq reporting zero problems. gdash cannot know it is wrong -- someone may
    ' mean ten dollars -- so the guard says what the number MEANS and lets a
    ' person decide in one glance.
    n = gdash_nlq.unit_notes("select count(*) from orders.orders where amount > 1000", scaled)
    s = gdash_test.eq(s, count(n), 1, "a bare number compared to a money column is noticed")
    s = gdash_test.eq(s, n[0].literal, "1000", "the literal is quoted back")
    s = gdash_test.contains_text(s, n[0].means, "$10.00", "restated in the column's own units")
    s = gdash_test.contains_text(s, n[0].column, "orders.amount", "naming the column it belongs to")

    ' And the query that is actually right raises the same note, because it is
    ' the same shape. Saying "$1,000.00" is how a reviewer confirms it.
    ok_n = gdash_nlq.unit_notes("select count(*) from orders.orders where amount > 100000", scaled)
    s = gdash_test.eq(s, count(ok_n), 1, "a correct query is restated too, not waved through")
    s = gdash_test.contains_text(s, ok_n[0].means, "1,000.00", "and reads as the number the asker had in mind")

    ' --- the spellings a generated query actually uses ----------------------
    forms = ["select 1 from t where amount > 1000",
             "select 1 from t where orders.amount > 1000",
             "select 1 from t where orders.orders.amount > 1000",
             "select 1 from t where AMOUNT > 1000",
             "select 1 from t where amount>1000",
             "select 1 from t where amount >= 1000",
             "select 1 from t having sum(amount) > 1000",
             "select 1 from t where 1000 < amount"]
    i = 0
    while i < count(forms)
        got = gdash_nlq.unit_notes(forms[i], scaled)
        s = gdash_test.eq(s, count(got), 1, "noticed in <" + forms[i] + ">")
        i += 1
    end while

    ' `between` never reaches a comparison operator, so it needs its own arm.
    bt = gdash_nlq.unit_notes("select 1 from t where amount between 1000 and 2000", scaled)
    s = gdash_test.eq(s, count(bt), 2, "both ends of a between are restated")
    s = gdash_test.contains_text(s, bt[1].means, "$20.00", "including the upper one")

    ' --- and what it must NOT say ------------------------------------------
    '
    ' A guard that fires on everything is one nobody reads, which is the
    ' 15-of-16 lesson from the library's own ambiguity refusal.
    quiet = ["select count(*) from orders.orders",
             "select region, sum(amount) from orders.orders group by region",
             "select 1 from t where month > 2026",
             "select 1 from t where region = 'north'",
             "select 1 from t limit 1000",
             "select 1 from t where label = 'amount > 1000'"]
    i = 0
    while i < count(quiet)
        got = gdash_nlq.unit_notes(quiet[i], scaled)
        s = gdash_test.eq(s, count(got), 0, "silent on <" + quiet[i] + ">")
        i += 1
    end while

    ' A dashboard with no money column gets no notes and pays no cost.
    s = gdash_test.eq(s, count(gdash_nlq.unit_notes("select 1 from t where amount > 1000", {})), 0, "no scaled columns, nothing to say")

    ' A column compared to another column is not compared to a literal.
    s = gdash_test.eq(s, count(gdash_nlq.unit_notes("select 1 from t where amount > budget", scaled)), 0, "a column compared to a column is not a magnitude question")

    ' --- a scale that is not two -------------------------------------------
    '
    ' Money is not always two places: JPY has none, and gdash records the scale
    ' per column precisely so nothing assumes.
    yen = {}
    yen["t.t.total"] = { dataset: "t", column: "total", scale: 0, currency: "JPY" }
    y = gdash_nlq.unit_notes("select 1 from t where total > 1000", yen)
    s = gdash_test.eq(s, count(y), 1, "a zero-decimal currency is still checked")
    s = gdash_test.contains_text(s, y[0].means, "1,000", "and 1000 minor units is 1000 of them")

    rate = {}
    rate["fx.fx.px"] = { dataset: "fx", column: "px", scale: 4, currency: "" }
    r = gdash_nlq.unit_notes("select 1 from fx.fx where px > 1", rate)
    s = gdash_test.eq(s, count(r), 1, "a four-decimal column is checked")
    s = gdash_test.contains_text(s, r[0].means, "0.0001", "where 1 is a ten-thousandth, not one")

    ' --- the catalog -------------------------------------------------------
    desc = { ok: true, message: "", datasets: {} }
    desc.datasets["orders"] = { columns: [ { name: "region", kind: "text", scale: 0 },
                                           { name: "amount", kind: "money", scale: 2 } ] }
    desc.datasets["regions"] = { columns: [ { name: "region", kind: "text", scale: 0 } ] }
    cat = gdash_nlq.catalog(desc)
    s = gdash_test.eq(s, count(cat.tables), 2, "every refreshed dataset is a table")
    s = gdash_test.eq(s, count(cat.columns), 3, "and every column of each is offered")
    s = gdash_test.eq(s, cat.tables[0].schema, "orders", "a dataset is its own schema")
    s = gdash_test.eq(s, cat.tables[0].table, "orders", "and its own table")
    ' Sorted, so a catalog does not depend on the order keys happen to come
    ' back in -- a grounding that changes because a record was re-saved would
    ' be very hard to believe.
    s = gdash_test.eq(s, cat.tables[1].schema, "regions", "and the order is stable")

    ' --- scaled_columns reads the record for currency ----------------------
    rec = { datasets: {} }
    rec["datasets"]["orders"] = { columns: {} }
    rec["datasets"]["orders"]["columns"]["amount"] = { type: "money", scale: 2, currency: "USD" }
    rec["datasets"]["regions"] = {}
    sc = gdash_nlq.scaled_columns(desc, rec)
    s = gdash_test.eq(s, count(keys(sc)), 1, "only money columns are scaled columns")
    s = gdash_test.eq(s, sc["orders.orders.amount"].currency, "USD", "currency comes from the record")
    s = gdash_test.eq(s, sc["orders.orders.amount"].scale, 2, "and the scale from what was materialized")

    ' A money column whose record says nothing about currency still has a
    ' scale, and the note must still be produced -- the scale is the part that
    ' makes the number wrong.
    rec2 = { datasets: {} }
    rec2["datasets"]["orders"] = {}
    sc2 = gdash_nlq.scaled_columns(desc, rec2)
    s = gdash_test.eq(s, sc2["orders.orders.amount"].currency, "", "no declared currency is not an error")
    n2 = gdash_nlq.unit_notes("select 1 from t where amount > 1000", sc2)
    s = gdash_test.eq(s, count(n2), 1, "and the column is still guarded")
    s = gdash_test.contains_text(s, n2[0].means, "10.00", "restated as a plain decimal")

    exit(gdash_test.report(s))
end program
