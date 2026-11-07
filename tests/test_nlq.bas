program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_nlq from "../src/gdash_nlq.bas"

    s = gdash_test.suite("nlq")

    ' --- the catalog -------------------------------------------------------
    '
    ' Every dataset is a table in the dashboard's one G-SQL database
    ' (GDASH-20), so the catalog names it BARE -- the same name a visual query
    ' uses. Before, every dataset was attached under its own schema and a
    ' generated query said `orders.orders`.
    desc = { ok: true, message: "", datasets: {} }
    desc.datasets["orders"] = { columns: [ { name: "region", kind: "text", scale: 0, currency: "" },
                                           { name: "amount", kind: "money", scale: 2, currency: "USD" } ] }
    desc.datasets["regions"] = { columns: [ { name: "region", kind: "text", scale: 0, currency: "" } ] }
    cat = gdash_nlq.catalog(desc)
    s = gdash_test.eq(s, count(cat.tables), 2, "every refreshed dataset is a table")
    s = gdash_test.eq(s, count(cat.columns), 3, "and every column of each is offered")
    s = gdash_test.eq(s, item_at(cat.tables, 0).schema, "", "a table has no schema")
    s = gdash_test.eq(s, item_at(cat.tables, 0).table, "orders", "and is named as the dataset")
    ' Sorted, so a catalog does not depend on the order keys happen to come
    ' back in -- a grounding that changes because a record was re-saved would
    ' be very hard to believe.
    s = gdash_test.eq(s, item_at(cat.tables, 1).table, "regions", "and the order is stable")

    ' --- money columns, and the currency each holds ------------------------
    '
    ' The currency is recorded in `_gdash_meta` at materialization; the
    ' record is the fallback for a dataset staged before it was.
    rec = { datasets: {} }
    rec["datasets"]["orders"] = { columns: {} }
    rec["datasets"]["regions"] = {}
    sc = gdash_nlq.scaled_columns(desc, rec)
    s = gdash_test.eq(s, count(keys(sc)), 1, "only money columns are listed")
    s = gdash_test.eq(s, string(keys(sc)), string(["orders.amount"]), "keyed the way a bare-table grounding names it")
    s = gdash_test.eq(s, sc["orders.amount"].currency, "USD", "with the currency gdash recorded")
    s = gdash_test.eq(s, sc["orders.amount"].scale, 2, "and the display scale")

    old = { ok: true, message: "", datasets: {} }
    old.datasets["orders"] = { columns: [ { name: "amount", kind: "money", scale: 2, currency: "" } ] }
    rec2 = { datasets: {} }
    rec2["datasets"]["orders"] = { columns: {} }
    rec2["datasets"]["orders"]["columns"]["amount"] = { type: "money", scale: 2, currency: "EUR" }
    s = gdash_test.eq(s, gdash_nlq.scaled_columns(old, rec2)["orders.amount"].currency, "EUR", "the record supplies a currency the metadata lacks")

    ' --- the note that reaches the model -----------------------------------
    '
    ' The note used to say how to convert dollars into cents, because
    ' `amount` held cents and `amount > 1000` silently meant ten dollars.
    ' Money is stored as money now, and G-SQL reads a plain number compared
    ' with a money column as that column's currency -- so the note says which
    ' currency, and that a plain number is an amount of it.
    pn = gdash_nlq.prompt_notes(sc)
    s = gdash_test.eq(s, count(keys(pn)), 1, "a note per money column")
    s = gdash_test.contains_text(s, string(pn["orders.amount"]), "money in USD", "the note names the currency")
    s = gdash_test.contains_text(s, string(pn["orders.amount"]), "the literal 1000 means USD 1000", "and says a plain number is an amount of it")
    s = gdash_test.ok(s, not contains(lower(string(pn["orders.amount"])), "minor unit"), "and says nothing about minor units, which no longer exist")
    bare = {}
    bare["fx.px"] = { dataset: "fx", column: "px", scale: 4, currency: "" }
    s = gdash_test.contains_text(s, string(gdash_nlq.prompt_notes(bare)["fx.px"]), "money", "a money column with no known currency is still described")
    s = gdash_test.eq(s, count(keys(gdash_nlq.prompt_notes({}))), 0, "a dashboard with no money columns needs no notes")

    ' --- the tokenizer promotion reads a select list with ---------------------
    toks = gdash_nlq.tokens("select sum(amount) as total from orders where label = 'a > b'")
    words = []
    for each t in toks
        if t.kind = "string" then
            words = append(words, t.text)
        end if
    next
    s = gdash_test.eq(s, string(words), string(["'a > b'"]), "a string literal is one token, operators and all")

    exit(gdash_test.report(s))
end program

' Indexing a list that came back shorter than expected RAISES, which kills the
' run at the first surprise and hides every assertion after it. So every
' indexed read goes through here and a missing entry fails its own assertion.
function item_at(list, i)
    if i < count(list) then
        return list[i]
    end if
    return { schema: "(none)", table: "(none)", column: "(none)" }
end function
