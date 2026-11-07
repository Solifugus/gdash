' Encoding channels checked against what a query really returns (GDASH-21).
'
' The check describes each visual's query from its plan (G-SQL's
' db.columns), with nothing run, against the draft's staged data. These pin
' what it refuses, what it only warns about, what it cannot check -- and that
' publish refuses on it.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_channels from "../src/gdash_channels.bas"
    load gdash_publish from "../src/gdash_publish.bas"
    load gdash_record from "../src/gdash_record.bas"

    s = gdash_test.suite("channels")
    root = args[0]
    p = gdash_paths.roles(root)

    ' --- the staged data: orders, with money; regions, text only ---
    made = gdash_paths.ensure_dir(gdash_paths.data_dir(p, "sales", "draft"))
    db = gdash_paths.stage_db(p, "sales", "draft")
    orows = [["west", "2026-01", "1250.75"], ["east", "2026-02", "640.10"]]
    m1 = gdash_store.materialize(db, "orders", gdash_store.plan_columns(["region", "month", "amount"], orows, { amount: { type: "money", scale: 2 } }), orows)
    w1 = gdash_store.swap(db, "orders")
    rrows = [["west", "Ada"], ["east", "Bo"]]
    m2 = gdash_store.materialize(db, "regions", gdash_store.plan_columns(["region", "manager"], rrows, {}), rrows)
    w2 = gdash_store.swap(db, "regions")
    s = gdash_test.ok(s, w1.ok and w2.ok, "two datasets staged")

    ' --- what the store reports, from the plan ---
    d = gdash_store.columns(db, "select region, sum(amount) as total from orders where region = :region group by region")
    s = gdash_test.ok(s, d.ok, "a query with a :param is described without a value for it -- " + d.message)
    s = gdash_test.eq(s, count(d.columns), 2, "two result columns")
    s = gdash_test.eq(s, string(d.columns[0].name), "region", "in select-list order")
    s = gdash_test.eq(s, string(d.columns[0].kind), "string", "a plain column carries its kind")
    bad = gdash_store.columns(db, "select region from orders group by")
    s = gdash_test.ok(s, not bad.ok, "a query that does not compile is a value, not a raise")

    ' --- a record whose visuals all match ---
    good = { visuals: {
                 total: { dataset: "orders", sql: "select sum(amount) as total from orders",
                          encoding: { mark: "value", value: "total", format: "currency" } },
                 by_region: { dataset: "orders", sql: "select region, sum(amount) as total from orders group by region",
                              encoding: { mark: "bar", x: "region", y: "total", format: "currency" } },
                 joined: { dataset: "orders", sql: "select r.manager as manager, sum(o.amount) as total from orders o join regions r on r.region = o.region group by r.manager",
                           encoding: { mark: "table", formats: { total: "currency" } } } },
             controls: { picker: { kind: "select", param: "region", dataset: "orders", sql: "select distinct region from orders" } } }
    g = gdash_channels.check_channels(good, db)
    s = gdash_test.eq(s, count(g.errors), 0, "matching channels raise nothing -- " + join(g.errors, "; "))
    s = gdash_test.eq(s, count(g.warnings), 0, "and warn about nothing")
    s = gdash_test.eq(s, count(g.unchecked), 0, "and every visual was checked")

    ' --- what is refused ---
    wrong = { visuals: {
                  typo: { dataset: "orders", sql: "select region, sum(amount) as total from orders group by region",
                          encoding: { mark: "bar", x: "region", y: "totl" } },
                  broken: { dataset: "orders", sql: "select region from orders group by",
                            encoding: { mark: "table" } },
                  tablefmt: { dataset: "orders", sql: "select region, amount from orders",
                              encoding: { mark: "table", formats: { amout: "currency" } } },
                  seriesless: { dataset: "orders", sql: "select month, sum(amount) as total from orders group by month",
                                encoding: { mark: "line", x: "month", y: "total", series: "region" } } },
              controls: { picker: { kind: "select", param: "region", dataset: "orders", sql: "select distinct regoin from orders" } } }
    w = gdash_channels.check_channels(wrong, db)
    we = join(w.errors, " | ")
    s = gdash_test.contains_text(s, we, "visual 'typo': channel 'y' names column 'totl', which its query does not return (it returns region, total)", "a mistyped channel is named, with what the query does return")
    s = gdash_test.contains_text(s, we, "visual 'broken': its query does not compile", "a query that does not compile is caught before anyone opens it")
    s = gdash_test.contains_text(s, we, "visual 'tablefmt': a format names column 'amout'", "a table format naming no column is caught, where it used to do nothing silently")
    s = gdash_test.contains_text(s, we, "visual 'seriesless': channel 'series' names column 'region'", "an optional channel is checked when it is set")
    s = gdash_test.contains_text(s, we, "control 'picker': its options query does not compile", "a control whose options query does not compile is caught")

    ' --- what is only warned about ---
    ' A currency format over text is a mistake gdash can see only for a plain
    ' column: a computed one is described as `any`.
    textmoney = { visuals: { v: { dataset: "orders", sql: "select region, month from orders",
                                  encoding: { mark: "table", formats: { region: "currency" } } } } }
    tm = gdash_channels.check_channels(textmoney, db)
    s = gdash_test.eq(s, count(tm.errors), 0, "a currency format over text is not refused")
    s = gdash_test.contains_text(s, join(tm.warnings, " | "), "'region' is formatted as currency, but it is string, not an amount", "but it is warned about")

    ' --- what cannot be checked is said, never passed ---
    cold = { visuals: { v: { dataset: "ledger", sql: "select nonsense from ledger",
                             encoding: { mark: "value", value: "whatever" } } } }
    c = gdash_channels.check_channels(cold, db)
    s = gdash_test.eq(s, count(c.errors), 0, "a dataset that has never refreshed is not an error")
    s = gdash_test.contains_text(s, join(c.unchecked, " | "), "dataset 'ledger' has not refreshed", "it is reported as not checked")

    ' --- publish refuses a visual that does not match its query ---
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "sales"))
    rf {file} = gdash_paths.record_file(p, "sales")
    base = { format: 1, name: "sales", access: "open",
             datasets: { orders: { profile: "fake", sql: "select 1" }, regions: { profile: "fake", sql: "select 1" } },
             params: {}, visuals: { typo: wrong.visuals.typo }, tabs: [{ name: "S", layout: { vert: [{ visual: "typo" }] } }] }
    write(rf, encode(base))
    s = gdash_test.ok(s, gdash_record.load_file(gdash_paths.record_file(p, "sales")).ok, "the record itself validates: only its channel is wrong")
    pub = gdash_publish.publish(p, "sales")
    s = gdash_test.ok(s, not pub.ok, "publish refuses it")
    s = gdash_test.contains_text(s, join(pub.errors, " | "), "names column 'totl'", "naming the column")
    s = gdash_test.ok(s, not gdash_paths.publication(p, "sales").published, "and nothing was published")

    fixed = base
    fixed["visuals"] = { by_region: good.visuals.by_region }
    fixed["tabs"] = [{ name: "S", layout: { vert: [{ visual: "by_region" }] } }]
    write(rf, encode(fixed))
    pub2 = gdash_publish.publish(p, "sales")
    s = gdash_test.ok(s, pub2.ok, "once it matches, it publishes -- " + pub2.message + " " + join(pub2.errors, "; "))

    ' And a first publish before any refresh -- the documented first-run order
    ' -- is not refused: what cannot be checked is noted.
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "fresh"))
    ff {file} = gdash_paths.record_file(p, "fresh")
    write(ff, encode({ format: 1, name: "fresh", access: "open", datasets: { orders: { profile: "fake", sql: "select 1" } },
                       params: {}, visuals: { t: { dataset: "orders", sql: "select 1 as one from orders", encoding: { mark: "value", value: "one" } } },
                       tabs: [{ name: "F", layout: { vert: [{ visual: "t" }] } }] }))
    pub3 = gdash_publish.publish(p, "fresh")
    s = gdash_test.ok(s, pub3.ok, "a dashboard with no staged data still publishes")
    s = gdash_test.contains_text(s, join(pub3.notes, " | "), "has not refreshed", "and says what it could not check")

    exit(gdash_test.report(s))
end program
