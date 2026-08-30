program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_record from "../src/gdash_record.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_format from "../src/gdash_format.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"

    s = gdash_test.suite("refresh")
    root = args[0]
    p = gdash_paths.roles(root)

    ref = gdash_record.load_file("dashboards/sales/draft.json")
    s = gdash_test.ok(s, ref.ok, "reference record loads")
    rec = ref.record

    good = { kind: "fixture", path: "fixtures/orders.json" }
    live = gdash_paths.dataset_db(p, "sales", "orders")
    vfile = gdash_paths.version_file(p, "sales")

    ' --- a first refresh materializes the dataset ---
    r1 = gdash_refresh.run(p, "sales", rec, "orders", good)
    s = gdash_test.ok(s, r1.ok, "first refresh succeeds -- " + r1.message)
    s = gdash_test.ok(s, gdash_paths.path_exists(live), "live dataset file exists")
    s = gdash_test.eq(s, r1.version, 1, "version bumped to 1")

    ' Money materialized as INTEGER minor units, exact.
    tot = gdash_store.select_rows(live, "select sum(amount) as total from orders where region = :region", { region: "west" }, ["total"])
    s = gdash_test.ok(s, tot.ok, "visual query runs against the refreshed file")
    s = gdash_test.eq(s, tot.rows[0]["total__text"], "325100", "1250.75 + 900.25 + 1100.00 in minor units")
    s = gdash_test.eq(s, gdash_format.minor_to_decimal(tot.rows[0]["total__text"], 2), "3251.00", "renders exactly")

    ' Per-column scale travelled with the data.
    s = gdash_test.eq(s, gdash_store.money_columns(live)["amount"], 2, "scale recorded in _gdash_meta")

    ' --- a refresh that FAILS must leave the old file untouched ---
    ' (design §3: stale-but-coherent beats broken)
    before_bytes = ""
    lf {file} = live
    before_bytes = read(lf)
    before_version = gdash_store.read_version(vfile)

    down = { kind: "fixture", path: "fixtures/orders_unavailable.json" }
    r2 = gdash_refresh.run(p, "sales", rec, "orders", down)
    s = gdash_test.ok(s, not r2.ok, "refresh against an unavailable source fails")
    after_bytes = read(lf)
    s = gdash_test.eq(s, after_bytes, before_bytes, "failed refresh left the dataset file byte-identical")
    s = gdash_test.eq(s, gdash_store.read_version(vfile), before_version, "and did not bump the version")

    ' The old data is still queryable -- the dashboard keeps working.
    still = gdash_store.select_rows(live, "select sum(amount) as total from orders where region = :region", { region: "west" }, ["total"])
    s = gdash_test.eq(s, still.rows[0]["total__text"], "325100", "old data still readable after a failed refresh")

    ' --- a money value with too many decimals fails the whole refresh ---
    fat = { kind: "fixture", path: "fixtures/orders_excess_decimals.json" }
    r3 = gdash_refresh.run(p, "sales", rec, "orders", fat)
    s = gdash_test.ok(s, not r3.ok, "excess decimals fail the refresh")
    s = gdash_test.contains_text(s, r3.message, "rejected, not rounded", "and say why, from the child")
    s = gdash_test.eq(s, read(lf), before_bytes, "rejected refresh left the dataset untouched")

    ' --- no staging residue is left behind by any of the above ---
    staging = gdash_paths.dataset_staging(p, "sales", "orders")
    s = gdash_test.ok(s, not gdash_paths.path_exists(staging), "no staging file survives a run")

    ' --- the job file carrying credentials does not outlive the fetch ---
    jobf = gdash_paths.job_file(p, "sales-orders")
    s = gdash_test.ok(s, not gdash_paths.path_exists(jobf), "job file is removed after the refresh")

    ' --- a second successful refresh swaps and bumps again ---
    r4 = gdash_refresh.run(p, "sales", rec, "orders", good)
    s = gdash_test.ok(s, r4.ok, "later refresh succeeds again")
    s = gdash_test.eq(s, r4.version, before_version + 1, "version advances past the failures")

    exit(gdash_test.report(s))
end program
