program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_sched from "../src/gdash_sched.bas"
    load gdash_record from "../src/gdash_record.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_format from "../src/gdash_format.bas"
    load gdash_refresh from "../src/gdash_refresh.bas"
    load gdash_publish from "../src/gdash_publish.bas"

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

    ' --- a dataset directory that cannot be created (G14-1) ----------------
    '
    ' FOUND BY STARTING THE UNIT, which is what GDASH-14 was for. The install
    ' message tells an administrator to run the CLI before the service exists,
    ' so `/var/cache/gdash/<name>/` ends up owned by root while
    ' `/var/cache/gdash` is owned by the service user -- and the first refresh
    ' the SERVICE performs cannot create `published/` inside it.
    '
    ' Simulated here with a regular FILE where the directory must be, which
    ' fails the same way (ENOTDIR rather than EACCES) and needs no chmod, no
    ' second user and no container.
    '
    ' Two things were wrong. `ensure_dir`'s result was assigned and never
    ' checked; then the failing lock-file write left an error PENDING AND
    ' UNACKNOWLEDGED, and the `with lock` that followed raised into it and
    ' escaped the frame -- the exact hazard gdash's own notes warn about.
    blocked = { kind: "fixture", path: "fixtures/orders.json" }
    made = gdash_paths.ensure_dir(p.cache_dir + "/blocked")
    blocker {file} = p.cache_dir + "/blocked/published"
    write(blocker, "a regular file where a directory must be")

    brec = gdash_record.load_file("dashboards/sales/draft.json").record

    ' OBSERVED, NOT SUFFERED. The defect is that this RAISES and escapes the
    ' frame -- which a test cannot report by dying of it, and which would hide
    ' every assertion below. Catching it here turns the regression into a named
    ' failure instead of a stack trace.
    on error goto next
    rb = gdash_refresh.run(p, "blocked", "published", brec, "orders", blocked, "policy")
    raised = error
    s = gdash_test.ok(s, not raised, "run() RETURNS on a directory it cannot create, rather than raising")
    if raised then
        rb = { ok: false, message: "(it raised)", version: 0, rows: 0, unchanged: false, skipped: false }
    end if
    s = gdash_test.ok(s, not rb.ok, "and the outcome is a failure")
    s = gdash_test.contains_text(s, rb.message, "blocked", "and the message names the path")
    s = gdash_test.ok(s, not rb.unchanged, "it is not reported as unchanged")

    ' --- and one dashboard's failure must not stop the pass (G14-2) --------
    '
    ' `pass()` counts failures, so it was designed to be resilient -- but a
    ' RAISE bypassed the counting entirely and killed the whole scheduler run.
    ' One dashboard with a permissions problem took every other dashboard's
    ' refresh down with it, which turns a single misconfiguration into a total
    ' scheduling outage.
    '
    ' WHAT THIS ASSERTS, PRECISELY: that a dashboard whose refresh FAILS does
    ' not stop the pass. It does not exercise the `on error` guard now standing
    ' around `run` inside `pass` -- with the checks above in place, no fixture
    ' here can make `run` raise at all.
    '
    ' The guard is kept, and it is not merely decorative: measured under
    ' mutation in tests/run_systemd.sh, removing the inner checks while leaving
    ' the guard turns a runtime error that killed the whole pass into a counted
    ' failure that does not. It is what stands between a permission problem and
    ' a total scheduling outage if any future raise appears inside `run` --
    ' which calls into a network fetch, a child process, SQLite and a rename.
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "blocked"))
    bf {file} = gdash_paths.record_file(p, "blocked")
    write(bf, encode(brec))
    pub1 = gdash_publish.publish(p, "blocked")

    ' The healthy one needs an INTERVAL policy, or a policy pass correctly
    ' skips it and the assertion below proves nothing. (It failed exactly that
    ' way first time round, which is the fixture telling the truth.)
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "healthy"))
    hrec = brec
    for each dsname in keys(hrec["datasets"])
        hrec["datasets"][dsname]["refresh"] = "interval"
        hrec["datasets"][dsname]["every"] = 1
    next
    hf {file} = gdash_paths.record_file(p, "healthy")
    write(hf, encode(hrec))
    pub2 = gdash_publish.publish(p, "healthy")
    s = gdash_test.ok(s, pub1.ok and pub2.ok, "two dashboards published for the pass")

    ' `pass` resolves profiles from the connections file, where the tests above
    ' hand `run` a profile directly. Without this both dashboards fail -- one
    ' for the blocked directory and one for a missing profile -- and the
    ' assertion below would pass for the wrong reason.
    made = gdash_paths.ensure_dir(p.config_dir)
    cf {file} = gdash_paths.connections_file(p)
    write(cf, encode({ warehouse: { kind: "fixture", path: "fixtures/orders.json" },
                       regionbook: { kind: "fixture", path: "fixtures/regions.json" } }))

    result = gdash_refresh.pass(p)
    s = gdash_test.ok(s, result.failed > 0, "the blocked dashboard is counted as failed")
    s = gdash_test.ok(s, result.refreshed > 0, "AND THE HEALTHY ONE STILL REFRESHED -- the pass survived")
    s = gdash_test.contains_text(s, join(result.notes, " | "), "blocked", "the note names the dashboard that failed")

    exit(gdash_test.report(s))
end program
