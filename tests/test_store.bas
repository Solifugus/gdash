program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_format from "../src/gdash_format.bas"
    load gdash_paths from "../src/gdash_paths.bas"

    s = gdash_test.suite("store")
    root = args[0]
    made = gdash_paths.ensure_dir(root)

    ' --- money: decimal text -> integer minor units (design §4) ---
    s = gdash_test.eq(s, gdash_store.to_minor("1250.75", 2).minor, "125075", "two decimals at scale 2")
    s = gdash_test.eq(s, gdash_store.to_minor("1250.7", 2).minor, "125070", "short decimal is padded")
    s = gdash_test.eq(s, gdash_store.to_minor("1250", 2).minor, "125000", "whole number is scaled")
    s = gdash_test.eq(s, gdash_store.to_minor("-1250.75", 2).minor, "-125075", "negative preserved")
    s = gdash_test.eq(s, gdash_store.to_minor("0.01", 2).minor, "1", "one cent")
    s = gdash_test.eq(s, gdash_store.to_minor("0.00", 2).minor, "0", "zero")
    s = gdash_test.eq(s, gdash_store.to_minor("-0.00", 2).minor, "0", "negative zero normalizes")
    s = gdash_test.eq(s, gdash_store.to_minor("12", 0).minor, "12", "scale 0 passes through")

    ' Excess decimals are REJECTED, not rounded. This value would round
    ' cleanly to 10.01, so the test fails if anyone makes it "helpful".
    r = gdash_store.to_minor("10.005", 2)
    s = gdash_test.ok(s, not r.ok, "excess decimals rejected, not rounded")
    s = gdash_test.contains_text(s, r.message, "rejected, not rounded", "refusal says so plainly")
    s = gdash_test.ok(s, not gdash_store.to_minor("10.999", 2).ok, "a value that would round UP is still rejected")
    s = gdash_test.ok(s, not gdash_store.to_minor("abc", 2).ok, "non-numeric rejected")
    s = gdash_test.ok(s, not gdash_store.to_minor("1.2.3", 2).ok, "malformed decimal rejected")
    s = gdash_test.ok(s, not gdash_store.to_minor("", 2).ok, "empty rejected")

    ' --- exactness past 2^53, which is the whole point of the text boundary ---
    big = "92233720368547.75"
    conv = gdash_store.to_minor(big, 2)
    s = gdash_test.eq(s, conv.minor, "9223372036854775", "large money converts exactly")
    s = gdash_test.eq(s, gdash_format.minor_to_decimal(conv.minor, 2), big, "and round-trips back exactly")
    ' 2^53 + 1 in minor units survives the round trip as text.
    s = gdash_test.eq(s, gdash_format.minor_to_decimal("9007199254740993", 2), "90071992547409.93", "past 2^53 renders exactly")
    s = gdash_test.eq(s, gdash_format.minor_to_decimal("1", 2), "0.01", "one cent renders")
    s = gdash_test.eq(s, gdash_format.minor_to_decimal("-125075", 2), "-1250.75", "negative renders")

    ' --- type inference for undeclared columns (design §4) ---
    s = gdash_test.eq(s, gdash_store.infer_kind(["1", "2", "-3"]), "integer", "integer-looking -> integer")
    s = gdash_test.eq(s, gdash_store.infer_kind(["1.5", "2"]), "real", "numeric -> real")
    s = gdash_test.eq(s, gdash_store.infer_kind(["west", "east"]), "text", "else -> text")
    s = gdash_test.eq(s, gdash_store.infer_kind([]), "text", "no samples -> text")

    ' --- materialize, then read back exactly ---
    dbp = root + "/orders.db"
    cols = ["region", "month", "amount"]
    rows = [["west", "2026-01", "1250.75"], ["west", "2026-02", "900.25"], ["east", "2026-01", "10.00"]]
    declared = { amount: { type: "money", scale: 2 } }
    plan = gdash_store.plan_columns(cols, rows, declared)
    s = gdash_test.eq(s, plan[2].kind, "money", "declared money column planned as money")
    s = gdash_test.eq(s, plan[0].kind, "text", "region inferred text")

    m = gdash_store.materialize(dbp, "orders", plan, rows)
    s = gdash_test.ok(s, m.ok, "materialize succeeds")
    s = gdash_test.eq(s, string(gdash_store.table_columns(dbp, "orders")), string(cols), "table has the fetched columns")
    mc = gdash_store.money_columns(dbp, {})
    s = gdash_test.eq(s, mc["amount"], 2, "per-column scale lives in _gdash_meta")

    ' SUM over minor units is exact in SQLite and crosses back as text.
    res = gdash_store.select_rows(dbp, "select sum(amount) as total from orders where region = :region", { region: "west" }, ["total"], {})
    s = gdash_test.ok(s, res.ok, "visual query runs")
    s = gdash_test.eq(s, res.rows[0]["total__text"], "215100", "sum of 1250.75 + 900.25 in minor units")
    s = gdash_test.eq(s, gdash_format.minor_to_decimal(res.rows[0]["total__text"], 2), "2151.00", "renders as money exactly")

    ' The :name rewrite reached SQLite as a positional bind.
    res2 = gdash_store.select_rows(dbp, "select sum(amount) as total from orders where region = :region", { region: "east" }, ["total"], {})
    s = gdash_test.eq(s, res2.rows[0]["total__text"], "1000", "param actually filtered")

    ' A materialize that hits an excess-decimal value fails whole.
    bad = gdash_store.materialize(root + "/bad.db", "orders", plan, [["west", "2026-01", "1.005"]])
    s = gdash_test.ok(s, not bad.ok, "excess decimals fail the materialize")
    s = gdash_test.contains_text(s, bad.message, "rejected, not rounded", "and say why")

    ' --- the swap, and stale-but-coherent (design §3) ---
    live = root + "/live.db"
    stage = root + "/live__staging.db"
    p1 = gdash_store.materialize(live, "orders", plan, [["west", "2026-01", "1.00"]])
    p2 = gdash_store.materialize(stage, "orders", plan, [["west", "2026-01", "2.00"]])
    before = gdash_store.select_rows(live, "select cast(amount as text) as a from orders", {}, [], {})
    s = gdash_test.eq(s, before.rows[0].a, "100", "live file before swap")
    sw = gdash_store.swap(stage, live)
    s = gdash_test.ok(s, sw.ok, "swap succeeds")
    after = gdash_store.select_rows(live, "select cast(amount as text) as a from orders", {}, [], {})
    s = gdash_test.eq(s, after.rows[0].a, "200", "a fresh reader sees the new data")
    s = gdash_test.ok(s, not gdash_paths.path_exists(stage), "staging file is consumed by the rename")

    ' --- version file ---
    vp = root + "/version"
    s = gdash_test.eq(s, gdash_store.read_version(vp), 0, "absent version reads 0")
    s = gdash_test.eq(s, gdash_store.bump_version(vp, vp + ".tmp"), 1, "first bump")
    s = gdash_test.eq(s, gdash_store.bump_version(vp, vp + ".tmp"), 2, "second bump")
    s = gdash_test.eq(s, gdash_store.read_version(vp), 2, "version persists")

    ' --- two datasets, attached, joined unqualified (finding G2-2) ---
    ordersp = root + "/attach_orders.db"
    regionsp = root + "/attach_regions.db"
    oplan = [{ name: "region", kind: "text", scale: 0 }, { name: "amount", kind: "money", scale: 2 }]
    rplan = [{ name: "region", kind: "text", scale: 0 }, { name: "label", kind: "text", scale: 0 }]
    m1 = gdash_store.materialize(ordersp, "orders", oplan, [["w", "10.00"], ["e", "20.00"]])
    m2 = gdash_store.materialize(regionsp, "regions", rplan, [["w", "West"], ["e", "East"]])

    ' The join names the sibling table with no schema prefix at all.
    jr = gdash_store.select_rows(ordersp, "select r.label as label, cast(o.amount as text) as amt from orders o join regions r on r.region = o.region order by 1", {}, [], { regions: regionsp })
    s = gdash_test.ok(s, jr.ok, "a query joining two dataset files runs")
    s = gdash_test.eq(s, count(jr.rows), 2, "the join returns both rows")
    s = gdash_test.eq(s, jr.rows[0].label, "East", "the sibling dataset's column is readable")
    s = gdash_test.eq(s, jr.rows[0].amt, "2000", "the primary dataset's money is still exact")

    ' Without the attachment the same query fails, which is what makes the
    ' attachment (not some ambient search path) the thing doing the work.
    nr = gdash_store.select_rows(ordersp, "select count(*) as n from orders o join regions r on r.region = o.region", {}, [], {})
    s = gdash_test.ok(s, not nr.ok, "the same query fails with nothing attached")

    ' --- _gdash_meta is read schema-qualified (finding G2-3) ---
    ' Both files carry a _gdash_meta. regions has NO money column; orders has
    ' one at scale 2. An unqualified read would answer from whichever file is
    ' `main` and silently render money at the wrong scale.
    mc2 = gdash_store.money_columns(ordersp, { regions: regionsp })
    s = gdash_test.eq(s, mc2["amount"], 2, "the primary's money scale survives an attachment")

    ' The reverse direction is the one that would go wrong quietly: `main` is
    ' the file WITHOUT the money column, and the scale must not leak in from
    ' the attached sibling under an unqualified read.
    scaled8 = root + "/attach_scale8.db"
    m3 = gdash_store.materialize(scaled8, "fine", [{ name: "amount", kind: "money", scale: 8 }], [["1.00000000"]])
    mixed = gdash_store.money_columns(ordersp, { fine: scaled8 })
    s = gdash_test.eq(s, mixed["amount"], 2, "the primary wins a column-name collision across schemas")

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
