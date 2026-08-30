program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_sched from "../src/gdash_sched.bas"
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
    live = gdash_paths.dataset_db(p, "sales", "draft", "orders")
    vfile = gdash_paths.version_file(p, "sales", "draft")

    ' --- a first refresh materializes the dataset ---
    r1 = gdash_refresh.run(p, "sales", "draft", rec, "orders", good, "manual")
    s = gdash_test.ok(s, r1.ok, "first refresh succeeds -- " + r1.message)
    s = gdash_test.ok(s, gdash_paths.path_exists(live), "live dataset file exists")
    s = gdash_test.eq(s, r1.version, 1, "version bumped to 1")

    ' Money materialized as INTEGER minor units, exact.
    tot = gdash_store.select_rows(live, "select sum(amount) as total from orders where region = :region", { region: "west" }, ["total"], {})
    s = gdash_test.ok(s, tot.ok, "visual query runs against the refreshed file")
    s = gdash_test.eq(s, tot.rows[0]["total__text"], "325100", "1250.75 + 900.25 + 1100.00 in minor units")
    s = gdash_test.eq(s, gdash_format.minor_to_decimal(tot.rows[0]["total__text"], 2), "3251.00", "renders exactly")

    ' Per-column scale travelled with the data.
    s = gdash_test.eq(s, gdash_store.money_columns(live, {})["amount"], 2, "scale recorded in _gdash_meta")

    ' --- a refresh that FAILS must leave the old file untouched ---
    ' (design §3: stale-but-coherent beats broken)
    before_bytes = ""
    lf {file} = live
    before_bytes = read(lf)
    before_version = gdash_store.read_version(vfile)

    down = { kind: "fixture", path: "fixtures/orders_unavailable.json" }
    r2 = gdash_refresh.run(p, "sales", "draft", rec, "orders", down, "manual")
    s = gdash_test.ok(s, not r2.ok, "refresh against an unavailable source fails")
    after_bytes = read(lf)
    s = gdash_test.eq(s, after_bytes, before_bytes, "failed refresh left the dataset file byte-identical")
    s = gdash_test.eq(s, gdash_store.read_version(vfile), before_version, "and did not bump the version")

    ' The old data is still queryable -- the dashboard keeps working.
    still = gdash_store.select_rows(live, "select sum(amount) as total from orders where region = :region", { region: "west" }, ["total"], {})
    s = gdash_test.eq(s, still.rows[0]["total__text"], "325100", "old data still readable after a failed refresh")

    ' --- a money value with too many decimals fails the whole refresh ---
    fat = { kind: "fixture", path: "fixtures/orders_excess_decimals.json" }
    r3 = gdash_refresh.run(p, "sales", "draft", rec, "orders", fat, "manual")
    s = gdash_test.ok(s, not r3.ok, "excess decimals fail the refresh")
    s = gdash_test.contains_text(s, r3.message, "rejected, not rounded", "and say why, from the child")
    s = gdash_test.eq(s, read(lf), before_bytes, "rejected refresh left the dataset untouched")

    ' --- no staging residue is left behind by any of the above ---
    staging = gdash_paths.dataset_staging(p, "sales", "draft", "orders")
    s = gdash_test.ok(s, not gdash_paths.path_exists(staging), "no staging file survives a run")

    ' --- the job file carrying credentials does not outlive the fetch ---
    jobf = gdash_paths.job_file(p, "sales-draft-orders")
    s = gdash_test.ok(s, not gdash_paths.path_exists(jobf), "job file is removed after the refresh")

    ' --- an unchanged refresh does not bump the version ---
    ' Every open tab reloads on a bump, so refetching identical data must not
    ' reload every viewer to show them the same numbers.
    r4 = gdash_refresh.run(p, "sales", "draft", rec, "orders", good, "manual")
    s = gdash_test.ok(s, r4.ok, "later refresh succeeds again")
    s = gdash_test.ok(s, r4.unchanged, "refetching identical data reports unchanged")
    s = gdash_test.eq(s, r4.version, before_version, "and does not bump the version")
    s = gdash_test.ok(s, not gdash_paths.path_exists(staging), "the unchanged staging file is discarded, not swapped")

    ' --- changed data does bump it ---
    moved = { kind: "fixture", path: "fixtures/orders_moved.json" }
    r5 = gdash_refresh.run(p, "sales", "draft", rec, "orders", moved, "manual")
    s = gdash_test.ok(s, r5.ok, "a refresh over changed data succeeds")
    s = gdash_test.ok(s, not r5.unchanged, "and reports it changed")
    s = gdash_test.eq(s, r5.version, before_version + 1, "version advances past the failures")
    s = gdash_test.eq(s, r5.rows, 7, "the row count comes back from the child")

    ' --- the state file carries what the dashboard needs to be honest ---
    st = gdash_sched.read_state(gdash_paths.dataset_state(p, "sales", "draft", "orders"))
    s = gdash_test.eq(s, st.rows, 7, "state records the row count")
    s = gdash_test.eq(s, st.last_error, "", "a success clears the last error")
    s = gdash_test.ok(s, st.last_success > 0, "state records when the data arrived")
    s = gdash_test.eq(s, len(st.hash), 64, "state records the content hash")

    ' A failure records its reason and leaves last_success where it was, which
    ' is what lets the page say "this is stale, and here is why".
    r6 = gdash_refresh.run(p, "sales", "draft", rec, "orders", down, "manual")
    s = gdash_test.ok(s, not r6.ok, "the source goes down again")
    st2 = gdash_sched.read_state(gdash_paths.dataset_state(p, "sales", "draft", "orders"))
    s = gdash_test.contains_text(s, st2.last_error, "configured to fail", "state records why it failed")
    s = gdash_test.eq(s, st2.last_success, st.last_success, "a failure does not move last_success")

    ' --- draft datasets refresh manually only (design §3) ---
    ' Enforced at the entry point: an author's half-finished query must not be
    ' able to hammer a production source on a timer.
    denied = gdash_refresh.run(p, "sales", "draft", rec, "orders", good, "policy")
    s = gdash_test.ok(s, not denied.ok, "a policy trigger against a draft is refused")
    s = gdash_test.contains_text(s, denied.message, "draft datasets refresh manually only", "and says why")

    ' --- crash residue is swept, not trusted ---
    resid {file} = staging
    write(resid, "not a database")
    swept = gdash_refresh.sweep_staging(p, "sales", "draft", rec)
    s = gdash_test.eq(s, count(swept), 1, "the sweep found the crash residue")
    s = gdash_test.ok(s, not gdash_paths.path_exists(staging), "and removed it")
    s = gdash_test.eq(s, count(gdash_refresh.sweep_staging(p, "sales", "draft", rec)), 0, "a second sweep finds nothing")

    ' The sweep says so in the log: silently deleting files is how a sweep
    ' becomes indistinguishable from data loss.
    alf {file} = gdash_paths.audit_log(p)
    audit = read(alf)
    s = gdash_test.contains_text(s, audit, "sweep.staging", "the sweep is audited")
    s = gdash_test.contains_text(s, audit, "refresh.failed", "so is a failed refresh")
    s = gdash_test.contains_text(s, audit, "refresh.unchanged", "so is an unchanged one")
    s = gdash_test.ok(s, not contains(audit, "password"), "and no credential reaches the log")

    exit(gdash_test.report(s))
end program
