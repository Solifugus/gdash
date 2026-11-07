program main(args)
    load gsql
    load gdash_test from "gdash_test.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_format from "../src/gdash_format.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_sql from "../src/gdash_sql.bas"

    s = gdash_test.suite("store")
    root = args[0]
    made = gdash_paths.ensure_dir(root)

    ' --- type inference for undeclared columns (design §4) ---
    s = gdash_test.eq(s, gdash_store.infer_kind(["1", "2", "-3"]), "integer", "integer-looking -> integer")
    s = gdash_test.eq(s, gdash_store.infer_kind(["1.5", "2"]), "real", "numeric -> real")
    s = gdash_test.eq(s, gdash_store.infer_kind(["west", "east"]), "text", "else -> text")
    s = gdash_test.eq(s, gdash_store.infer_kind([]), "text", "no samples -> text")
    s = gdash_test.eq(s, gdash_store.infer_kind([unknown, "4"]), "integer", "an absent cell does not decide the kind")

    ' --- the plan carries currency and the display scale ---
    cols = ["region", "month", "amount"]
    rows = [["west", "2026-01", "1250.75"], ["west", "2026-02", "900.25"], ["east", "2026-01", "10.00"]]
    plan = gdash_store.plan_columns(cols, rows, { amount: { type: "money", scale: 2 } })
    s = gdash_test.eq(s, plan[2].kind, "money", "declared money column planned as money")
    s = gdash_test.eq(s, plan[2].currency, "USD", "and in USD when no currency is declared")
    s = gdash_test.eq(s, plan[0].kind, "text", "region inferred text")
    jplan = gdash_store.plan_columns(["v"], [["430000"]], { v: { type: "money", scale: 0, currency: "JPY" } })
    s = gdash_test.eq(s, jplan[0].currency, "JPY", "a declared currency is kept")

    ' --- one database per (dashboard, stage); a dataset is a table ---
    db = root + "/sales/data.gsql"
    made = gdash_paths.ensure_dir(root + "/sales")
    s = gdash_test.ok(s, not gdash_store.has_dataset(db, "orders"), "no database yet: no dataset, and no database created by asking")
    s = gdash_test.ok(s, not gdash_paths.path_exists(db), "a read does not create the database")

    m = gdash_store.materialize(db, "orders", plan, rows)
    s = gdash_test.ok(s, m.ok, "materialize succeeds -- " + m.message)
    s = gdash_test.ok(s, gdash_store.has_staging(db, "orders"), "materialize writes the STAGING table")
    s = gdash_test.ok(s, not gdash_store.has_dataset(db, "orders"), "and nothing is live until the swap")
    sw = gdash_store.swap(db, "orders")
    s = gdash_test.ok(s, sw.ok, "swap succeeds -- " + sw.message)
    s = gdash_test.ok(s, gdash_store.has_dataset(db, "orders"), "the dataset is live after the swap")
    s = gdash_test.ok(s, not gdash_store.has_staging(db, "orders"), "and the staging table is gone, renamed rather than copied")
    s = gdash_test.eq(s, string(gdash_store.table_columns(db, "orders")), string(cols), "the table has the fetched columns, in order")
    s = gdash_test.eq(s, gdash_store.money_columns(db)["amount"], 2, "the display scale is recorded in _gdash_meta")

    ' --- money is money: exact, with its currency ---
    res = gdash_store.select_rows(db, "select sum(amount) as total from orders where region = :region", { region: "west" })
    s = gdash_test.ok(s, res.ok, "visual query runs -- " + res.message)
    s = gdash_test.eq(s, type(res.rows[0].total), "money", "a sum of money comes back as money")
    s = gdash_test.eq(s, money.currency(res.rows[0].total), "USD", "in the column's currency")
    s = gdash_test.eq(s, money.text(res.rows[0].total, 2), "2151.00", "1250.75 + 900.25, exactly")
    res2 = gdash_store.select_rows(db, "select sum(amount) as total from orders where region = :region", { region: "east" })
    s = gdash_test.eq(s, money.text(res2.rows[0].total, 2), "10.00", "the param actually filtered")
    ' S3: a plain number compared with a money column is that column's currency.
    over = gdash_store.select_rows(db, "select count(*) as n from orders where amount > 1000", {})
    s = gdash_test.eq(s, over.rows[0].n, 1, "amount > 1000 means USD 1000, not 1000 cents")

    ' --- D4a: stored exactly, rounded only for a person ---
    exact_db = root + "/exact/data.gsql"
    made = gdash_paths.ensure_dir(root + "/exact")
    xplan = gdash_store.plan_columns(["amount"], [], { amount: { type: "money", scale: 2 } })
    xm = gdash_store.materialize(exact_db, "ledger", xplan, [["1250.7512"], ["0.0049"]])
    s = gdash_test.ok(s, xm.ok, "a value with more decimals than the display scale is STORED, not refused -- " + xm.message)
    xs = gdash_store.swap(exact_db, "ledger")
    xr = gdash_store.select_rows(exact_db, "select sum(amount) as s from ledger", {})
    s = gdash_test.eq(s, money.text(xr.rows[0].s), "1250.756100", "and summed at its true value")
    s = gdash_test.eq(s, gdash_format.currency(xr.rows[0].s, 2, "").text, "$1,250.76", "rounded only when shown")

    ' A seventh decimal of USD is more than money can hold: refused, naming
    ' the row and column, and the live table is untouched.
    bad = gdash_store.materialize(exact_db, "ledger", xplan, [["1.00"], ["2.1234567"]])
    s = gdash_test.ok(s, not bad.ok, "a value the currency cannot store fails the materialize")
    s = gdash_test.contains_text(s, bad.message, "row 1", "and names the row")
    s = gdash_test.contains_text(s, bad.message, "amount", "and the column")
    s = gdash_test.ok(s, not gdash_store.has_staging(db, "ledger"), "a refused materialize leaves no staging table")
    still = gdash_store.select_rows(exact_db, "select count(*) as n from ledger", {})
    s = gdash_test.eq(s, still.rows[0].n, 2, "the live table is untouched: stale-but-coherent")
    ' Trailing zeros are not excess precision (G9-6): a numeric(19,8) source
    ' sends `1100.00000000`, an exact whole amount, and it must not fail the
    ' refresh because it spells eight places. The platform reads it so since
    ' gbasic 8633507 (ask A6); this pins that through the store.
    padded = gdash_store.materialize(exact_db, "padded", xplan, [["1100.00000000"], ["12.34560000"], ["-0.50000000"]])
    s = gdash_test.ok(s, padded.ok, "zeros past the currency's places are not precision -- " + padded.message)
    psw = gdash_store.swap(exact_db, "padded")
    pr = gdash_store.select_rows(exact_db, "select sum(amount) as s from padded", {})
    ' Read only when there is a row: on a build without A6 the materialize above
    ' fails, and this must report that, not die indexing an empty result.
    padded_sum = "(no rows)"
    if pr.ok and count(pr.rows) > 0 then
        padded_sum = money.text(pr.rows[0].s)
    end if
    s = gdash_test.eq(s, padded_sum, "1111.845600", "and the values are exactly what they said")
    nonzero = gdash_store.materialize(exact_db, "padded", xplan, [["1.00000001"]])
    s = gdash_test.ok(s, not nonzero.ok, "but a non-zero eighth place is still refused")
    empty = gdash_store.materialize(exact_db, "ledger", xplan, [[""]])
    s = gdash_test.ok(s, not empty.ok, "an empty string is not an amount")

    ' --- integers past 2^53 cross no boundary ---
    iplan = gdash_store.plan_columns(["id"], [["9007199254740993"]], {})
    s = gdash_test.eq(s, iplan[0].kind, "integer", "a big id is inferred integer")
    im = gdash_store.materialize(db, "ids", iplan, [["9007199254740993"]])
    isw = gdash_store.swap(db, "ids")
    ir = gdash_store.select_rows(db, "select id from ids", {})
    s = gdash_test.eq(s, string(ir.rows[0].id), "9007199254740993", "2^53 + 1 comes back exactly")

    ' --- the swap under a live reader (design §3) ---
    ' The reader is a raw G-SQL connection holding a read snapshot, which is
    ' exactly what a worker mid-query is. It must keep the old rows until it
    ' finishes, and a fresh read after must see the new ones.
    p1 = gdash_store.materialize(db, "orders", plan, [["west", "2026-01", "1.00"]])
    p1s = gdash_store.swap(db, "orders")
    reader = gsql.connect(db)
    gsql.begin(reader, "read")
    held = gsql.query(reader, "select count(*) as n from orders")
    p2 = gdash_store.materialize(db, "orders", plan, [["west", "2026-01", "2.00"], ["east", "2026-01", "3.00"]])
    p2s = gdash_store.swap(db, "orders")
    s = gdash_test.ok(s, p2s.ok, "a swap commits while a reader holds a snapshot -- " + p2s.message)
    during = gsql.query(reader, "select count(*) as n from orders")
    s = gdash_test.eq(s, during[0].n, 1, "the reader keeps the table it started with")
    gsql.commit(reader)
    gsql.close(reader)
    after = gdash_store.select_rows(db, "select count(*) as n from orders", {})
    s = gdash_test.eq(s, after.rows[0].n, 2, "a fresh reader sees the new data")

    ' --- a crashed child's staging table is discarded, not trusted ---
    junk = gdash_store.materialize(db, "orders", plan, [["north", "2026-01", "9.00"]])
    s = gdash_test.ok(s, gdash_store.has_staging(db, "orders"), "a staging table left behind is visible as one")
    s = gdash_test.ok(s, gdash_store.discard_staging(db, "orders"), "and discarded")
    s = gdash_test.ok(s, not gdash_store.has_staging(db, "orders"), "so it is gone")
    s = gdash_test.eq(s, gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n, 2, "and the live table never saw it")

    ' --- every read is read-only at the engine ---
    ' The second line of defence behind nlq.check_sql: a generated `delete`
    ' that got past the check is refused by G-SQL itself.
    del = gdash_store.select_across(db, "delete from orders")
    s = gdash_test.ok(s, not del.ok, "a write through the read path is refused")
    s = gdash_test.contains_text(s, del.message, "READ_ONLY", "by the engine, as read-only")
    s = gdash_test.eq(s, gdash_store.select_rows(db, "select count(*) as n from orders", {}).rows[0].n, 2, "and nothing was deleted")
    viarows = gdash_store.select_rows(db, "delete from orders", {})
    s = gdash_test.ok(s, not viarows.ok, "the visual-query path refuses a write the same way")

    ' --- siblings are tables in the same database: joined with no prefix ---
    rplan = gdash_store.plan_columns(["region", "label"], [["west", "West"]], {})
    rm = gdash_store.materialize(db, "regions", rplan, [["west", "West"], ["east", "East"]])
    rs = gdash_store.swap(db, "regions")
    jr = gdash_store.select_rows(db, "select r.label as label, sum(o.amount) as amt from orders o join regions r on r.region = o.region group by r.label order by 1", {})
    s = gdash_test.ok(s, jr.ok, "a query joining two datasets runs -- " + jr.message)
    s = gdash_test.eq(s, count(jr.rows), 2, "the join returns both rows")
    s = gdash_test.eq(s, jr.rows[0].label, "East", "the sibling's column is readable")
    s = gdash_test.eq(s, money.text(jr.rows[0].amt, 2), "3.00", "and the money is still exact")

    ' --- no dataset limit (the SQLite attach cap is gone) ---
    many = root + "/many/data.gsql"
    made = gdash_paths.ensure_dir(root + "/many")
    k = 0
    ok_all = true
    while k < 20
        one = gdash_store.materialize(many, "d" + string(k), gdash_store.plan_columns(["k", "v"], [["1", "x"]], {}), [["1", "v" + string(k)]])
        two = gdash_store.swap(many, "d" + string(k))
        ok_all = ok_all and one.ok and two.ok
        k += 1
    end while
    s = gdash_test.ok(s, ok_all, "twenty datasets in one dashboard")
    far = gdash_store.select_rows(many, "select a.v as a, b.v as b from d0 a join d19 b on a.k = b.k", {})
    s = gdash_test.ok(s, far.ok, "a query naming the first and the twentieth runs -- " + far.message)
    s = gdash_test.eq(s, far.rows[0].b, "v19", "and reads the twentieth")

    ' --- the wall between dashboards is the directory ---
    ' `orders` lives in the sales database. A query run against another
    ' dashboard's database cannot name it, however it is spelled.
    other = root + "/hr/data.gsql"
    made = gdash_paths.ensure_dir(root + "/hr")
    hm = gdash_store.materialize(other, "staff", gdash_store.plan_columns(["n"], [["a"]], {}), [["a"]])
    hs = gdash_store.swap(other, "staff")
    cross = gdash_store.select_rows(other, "select count(*) as n from orders", {})
    s = gdash_test.ok(s, not cross.ok, "one dashboard's query cannot name another dashboard's table")
    s = gdash_test.ok(s, not gdash_store.has_dataset(other, "orders"), "nor does the other dashboard have it")

    ' --- money_columns: a name meaning two scales is a conflict (G13-2) ---
    mix = root + "/mix/data.gsql"
    made = gdash_paths.ensure_dir(root + "/mix")
    a1 = gdash_store.materialize(mix, "usd", gdash_store.plan_columns(["amount"], [], { amount: { type: "money", scale: 2 } }), [["1.00"]])
    a2 = gdash_store.swap(mix, "usd")
    b1 = gdash_store.materialize(mix, "fine", gdash_store.plan_columns(["amount"], [], { amount: { type: "money", scale: 6 } }), [["1.000001"]])
    b2 = gdash_store.swap(mix, "fine")
    s = gdash_test.eq(s, gdash_store.money_columns(mix)["amount"], -2, "a column name meaning two display scales is a conflict, not a guess")
    c1 = gdash_store.materialize(mix, "fine", gdash_store.plan_columns(["amount"], [], { amount: { type: "money", scale: 2 } }), [["1.00"]])
    c2 = gdash_store.swap(mix, "fine")
    s = gdash_test.eq(s, gdash_store.money_columns(mix)["amount"], 2, "the same name at the same scale in two datasets is not a conflict")
    s = gdash_test.ok(s, gdash_store.reserved("_gdash_meta") and gdash_store.reserved("orders__staging") and not gdash_store.reserved("orders"), "the store's own names are reserved")

    ' --- describe: gdash's own account of what it wrote ---
    d = gdash_store.describe_datasets(db)
    s = gdash_test.ok(s, d.ok, "describe answers")
    s = gdash_test.eq(s, string(sort(keys(d.datasets))), string(["ids", "orders", "regions"]), "every live dataset, and no staging table")
    s = gdash_test.eq(s, d.datasets["orders"].columns[2].currency, "USD", "with each money column's currency")
    s = gdash_test.eq(s, string(gdash_store.sample_column(db, "regions", "label", 5)), string(["West", "East"]), "a column's values sampled")

    ' --- version file ---
    vp = root + "/version"
    s = gdash_test.eq(s, gdash_store.read_version(vp), 0, "absent version reads 0")
    s = gdash_test.eq(s, gdash_store.bump_version(vp, vp + ".tmp"), 1, "first bump")
    s = gdash_test.eq(s, gdash_store.bump_version(vp, vp + ".tmp"), 2, "second bump")
    s = gdash_test.eq(s, gdash_store.read_version(vp), 2, "version persists")

    ' --- content hash: the same content hashes the same, and only that ---
    h1 = gdash_store.content_hash(["a", "b"], [["1", "2"], ["3", "4"]])
    h2 = gdash_store.content_hash(["a", "b"], [["1", "2"], ["3", "4"]])
    h3 = gdash_store.content_hash(["a", "b"], [["1", "2"], ["3", "5"]])
    s = gdash_test.eq(s, h1, h2, "identical content hashes identically")
    s = gdash_test.ok(s, h1 != h3, "one changed cell changes the hash")
    s = gdash_test.ok(s, h1 != gdash_store.content_hash(["a", "c"], [["1", "2"], ["3", "4"]]), "a renamed column changes the hash")
    s = gdash_test.ok(s, h1 != gdash_store.content_hash(["a", "b"], [["3", "4"], ["1", "2"]]), "reordered rows change the hash")
    ' A hex digest, because len() lies about raw digest bytes (finding G2-5).
    s = gdash_test.eq(s, len(h1), 64, "the hash is 64 hex characters")

    exit(gdash_test.report(s))
end program
