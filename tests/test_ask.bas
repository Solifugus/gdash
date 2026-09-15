' The NLQ pipeline, against real staged data and a scripted model.
'
' The pipeline is `nlq.plan` -> a model -> `nlq.interpret` -> run the SQL ->
' `nlq.settle`, and every step of it can go wrong in a way a person has to be
' told about. A real model cannot be made to return the same wrong thing twice,
' so the model is the seam and this suite scripts it.
'
' The assertion this file exists for is the money one, under "the failure that
' started this phase". Everything else is the machinery around it.

program main(args)
    load gdash_test from "gdash_test.bas"
    load model_double from "model_double.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_ask from "../src/gdash_ask.bas"
    load gdash_record from "../src/gdash_record.bas"

    s = gdash_test.suite("ask")
    root = args[0]
    p = gdash_paths.roles(root)

    rec = { datasets: {} }
    rec["datasets"]["orders"] = { columns: {} }
    rec["datasets"]["orders"]["columns"]["amount"] = { type: "money", scale: 2, currency: "USD" }
    rec["datasets"]["regions"] = {}

    ' --- nothing refreshed yet ---------------------------------------------
    '
    ' A DASHBOARD NAME NOTHING ELSE IN THIS FILE USES. Asking "sales" here
    ' worked only because the root happened to be empty at this point, so the
    ' assertion silently depended on running before the staging below AND on
    ' the caseroot being fresh. A mutation run against a reused scratch
    ' directory failed it, which is the assertion telling the truth about
    ' itself: it was testing the directory, not the code.
    cold = gdash_ask.ask(p, "coldstart", "draft", rec, "how many orders?", model_double.saying("select 1"), {})
    s = gdash_test.ok(s, not cold.ok, "a dashboard with no data cannot be asked")
    s = gdash_test.eq(s, cold.stage, "data", "and it says so as a stage, not as a failure")
    s = gdash_test.contains_text(s, cold.message, "refreshed", "in words an operator can act on")

    ' --- stage the data ----------------------------------------------------
    made = gdash_paths.ensure_dir(gdash_paths.data_dir(p, "sales", "draft"))
    ocols = ["region", "month", "amount"]
    orows = [["west", "2026-01", "1250.75"], ["east", "2026-02", "1100.00"], ["west", "2026-03", "900.25"]]
    oplan = gdash_store.plan_columns(ocols, orows, { amount: { type: "money", scale: 2 } })
    m = gdash_store.materialize(gdash_paths.dataset_db(p, "sales", "draft", "orders"), "orders", oplan, orows)
    s = gdash_test.ok(s, m.ok, "the orders dataset materializes")

    rcols = ["region", "manager"]
    rrows = [["west", "Ada"], ["east", "Grace"]]
    rplan = gdash_store.plan_columns(rcols, rrows, {})
    m2 = gdash_store.materialize(gdash_paths.dataset_db(p, "sales", "draft", "regions"), "regions", rplan, rrows)
    s = gdash_test.ok(s, m2.ok, "and so does regions")

    ' --- an empty question -------------------------------------------------
    blank = gdash_ask.ask(p, "sales", "draft", rec, "   ", model_double.saying("select 1"), {})
    s = gdash_test.ok(s, not blank.ok, "an empty question is refused")
    s = gdash_test.eq(s, blank.stage, "ground", "before anything is spent on it")

    ' --- what gdash tells the model ----------------------------------------
    '
    ' The prompt is the half gdash is responsible for. `nlq` builds it, but
    ' only gdash can put real tables, real columns and real values in it.
    logp = root + "/prompt.log"
    wire = model_double.saying_into("select count(*) as n from orders.orders", logp)
    good = gdash_ask.ask(p, "sales", "draft", rec, "how many orders are there?", wire, {})
    said = model_double.prompted(logp)
    s = gdash_test.contains_text(s, said, "orders.orders", "the model is told the dataset is its own schema")
    s = gdash_test.contains_text(s, said, "amount", "and the columns it may use")
    s = gdash_test.contains_text(s, said, "west", "and the values a text column actually holds")
    s = gdash_test.contains_text(s, said, "SQLite", "and which SQL it is writing")

    ' --- the happy path ----------------------------------------------------
    s = gdash_test.ok(s, good.ok, "a good query answers")
    s = gdash_test.eq(s, good.stage, "answered", "at the answered stage")
    s = gdash_test.eq(s, string(good.answer.value), "3", "with the value the query returned")
    s = gdash_test.eq(s, good.sql, "select count(*) as n from orders.orders", "carrying the query it ran")
    s = gdash_test.ok(s, count(good.as_of) = 2, "and when each dataset was last refreshed")
    s = gdash_test.ok(s, good.key != "", "a plan key comes back for a caller that wants to cache")

    ' A fenced reply is still a query -- models fence SQL whatever they are
    ' told, and nlq strips it. Asserted here because the pipeline is what would
    ' break if it stopped.
    fenced = gdash_ask.ask(p, "sales", "draft", rec, "how many orders are there?",
                           model_double.saying("```sql" + chr(10) + "select count(*) as n from orders.orders" + chr(10) + "```"), {})
    s = gdash_test.ok(s, fenced.ok, "a fenced reply is still a query")

    ' --- was the model told what the integers mean? -------------------------
    '
    ' `units_told` is false when the installed `nlq` is too old to accept
    ' `notes`, which is a real state: the stdlib installs separately from the
    ' interpreter and the two move apart routinely. It must NOT be silent --
    ' the whole hazard is a confident wrong number, and "the model was not told
    ' the units" is exactly the context a reviewer needs.
    s = gdash_test.ok(s, good.units_told or not good.units_told, "a draft carries whether the model was told the units")
    s = gdash_test.ok(s, not is_unknown(good.units_told), "and it is always present, never unknown")
    s = gdash_test.ok(s, not is_unknown(cold.units_told), "including on a draft that stopped before planning")

    ' --- THE FAILURE THAT STARTED THIS PHASE -------------------------------
    '
    ' Step 0 measured this against the shipped library: the question is about
    ' DOLLARS, the column holds CENTS, the SQL is valid, nlq reports no
    ' problems, and the number is wrong by a factor of a hundred. gdash cannot
    ' refuse it -- someone may genuinely mean ten dollars -- so the whole of
    ' the defence is that the draft says what the number means.
    money = gdash_ask.ask(p, "sales", "draft", rec, "how many orders were over 1000 dollars?",
                          model_double.saying("select count(*) as n from orders.orders where amount > 1000"), {})
    s = gdash_test.ok(s, money.ok, "the wrong query is accepted, because it is valid")
    s = gdash_test.eq(s, string(money.answer.value), "3", "and returns the wrong answer")
    s = gdash_test.eq(s, count(money.notes), 1, "and the draft carries a unit note")
    s = gdash_test.contains_text(s, note_at(money.notes, 0).means, "$10.00", "saying what 1000 means in that column")

    ' The right query returns 2 and is restated too, which is how a reviewer
    ' confirms rather than assumes.
    right = gdash_ask.ask(p, "sales", "draft", rec, "how many orders were over 1000 dollars?",
                          model_double.saying("select count(*) as n from orders.orders where amount > 100000"), {})
    s = gdash_test.eq(s, string(right.answer.value), "2", "the correct query returns the true answer")
    s = gdash_test.contains_text(s, note_at(right.notes, 0).means, "1,000.00", "and is restated as well, not waved through")

    ' --- two refusals, two different things to say -------------------------
    '
    ' `nlq.plan` refuses on AMBIGUITY and -- since 2026-09-14, at gdash's own
    ' request -- on NOTHING GROUNDED. Both arrive as `ok: false` with
    ' `refused_because`, so the KIND has to be read. Telling someone "that
    ' could mean more than one thing" when the dashboard has no such data at
    ' all sends them looking for a disambiguation that does not exist.
    '
    ' gdash reported this shape to the platform and then made exactly that
    ' mistake against the fixed library the first time it ran. Tested here on
    ' synthetic plan values rather than through the library, so the assertion
    ' holds whichever version is installed.
    amb = { ok: false, refused_because: [{ kind: "ambiguous_object", candidates: ["a.b", "c.d"], why: "two tables" }] }
    s = gdash_test.contains_text(s, gdash_ask._refusal_words(amb), "more than one thing", "an ambiguity reads as an ambiguity")

    none_g = { ok: false, refused_because: [{ kind: "nothing_grounded", candidates: ["share", "price"], why: "matched nothing" }] }
    words = gdash_ask._refusal_words(none_g)
    s = gdash_test.contains_text(s, words, "no data that could answer", "a question that grounds nothing reads as that instead")
    s = gdash_test.contains_text(s, words, "share, price", "and names the words that reached nothing")
    s = gdash_test.ok(s, not contains(words, "more than one thing"), "and does not offer a choice that does not exist")

    ' A refusal carrying no candidates must still say the right kind of thing.
    bare_g = { ok: false, refused_because: [{ kind: "nothing_grounded", candidates: [], why: "" }] }
    s = gdash_test.contains_text(s, gdash_ask._refusal_words(bare_g), "no data that could answer", "with or without the words")

    ' --- a question this dashboard cannot answer at all ---------------------
    '
    ' `nlq.plan` refuses on AMBIGUITY and does NOT refuse a question the
    ' catalog has nothing to do with: it returns `ok` with a prompt naming no
    ' tables. Found by tests/nlq_corpus.bas -- five questions about data this
    ' dashboard has never heard of all planned `ok`, and every one would have
    ' been sent to a model, paid for, and then refused by check_sql for naming
    ' a table nobody offered. The model double makes that visible here: if the
    ' check were missing, this would reach the wire and come back as SQL.
    unanswerable = gdash_ask.ask(p, "sales", "draft", rec, "what is the share price?",
                            model_double.saying("select 1 as price"), {})
    s = gdash_test.ok(s, not unanswerable.ok, "a question about data that is not here is refused")
    s = gdash_test.eq(s, unanswerable.stage, "ground", "before a model is called at all")
    s = gdash_test.contains_text(s, unanswerable.message, "share", "naming the words nothing here matches")
    s = gdash_test.eq(s, unanswerable.sql, "", "and no query was produced")

    ' --- what the model can do wrong ---------------------------------------
    del = gdash_ask.ask(p, "sales", "draft", rec, "remove the west orders",
                        model_double.saying("delete from orders.orders where region = 'west'"), {})
    s = gdash_test.ok(s, not del.ok, "a write is refused")
    s = gdash_test.eq(s, del.stage, "sql", "by the SQL check, before anything runs")
    s = gdash_test.ok(s, count(del.problems) > 0, "with a problem to show")
    s = gdash_test.eq(s, del.sql, "delete from orders.orders where region = 'west'", "and the query it refused")

    ' The question grounds -- it is about orders -- and the model answers about
    ' something else entirely. That is the case check_sql exists for, and it is
    ' reachable only from a question that DID ground: "how many payroll runs?"
    ' now stops one step earlier, at the catalog, which is better and is a
    ' different assertion.
    stranger = gdash_ask.ask(p, "sales", "draft", rec, "how many orders are there?",
                             model_double.saying("select count(*) from payroll.payroll"), {})
    s = gdash_test.ok(s, not stranger.ok, "a query naming a table that is not there is refused")
    s = gdash_test.eq(s, stranger.stage, "sql", "by the SQL check, since the question itself was answerable")

    prose = gdash_ask.ask(p, "sales", "draft", rec, "how many orders?",
                          model_double.saying("I am afraid I cannot help with that."), {})
    s = gdash_test.ok(s, not prose.ok, "prose instead of SQL is refused")

    ' Valid, read-only, every name grounded -- and it does not compile. Only
    ' the database can find this one, which is why there is a `run` stage.
    broken = gdash_ask.ask(p, "sales", "draft", rec, "how many orders?",
                           model_double.saying("select count(*) from orders.orders group by"), {})
    s = gdash_test.ok(s, not broken.ok, "a query that does not compile is a reportable outcome")
    s = gdash_test.eq(s, broken.stage, "run", "at the run stage, not as a crash")
    s = gdash_test.eq(s, broken.sql, "select count(*) from orders.orders group by", "with the query that failed")

    ' --- the gate behind the gate ------------------------------------------
    '
    ' `nlq.check_sql` refuses a write and is the reason `del` above never ran.
    ' This asserts the thing underneath it: every dataset is ATTACHED READ-ONLY,
    ' so a gap in that check is harmless rather than destructive. It goes
    ' straight to the store, because the point is to test what happens when the
    ' check above it does not fire.
    only = { orders: gdash_paths.dataset_db(p, "sales", "draft", "orders") }
    wrote = gdash_store.select_across(only, "delete from orders.orders")
    s = gdash_test.ok(s, not wrote.ok, "a write through an attached dataset is refused by SQLite itself")
    still = gdash_store.select_across(only, "select count(*) as n from orders.orders")
    s = gdash_test.eq(s, string(still.rows[0].n), "3", "and the data is still there")

    ' --- the model itself being unreachable --------------------------------
    down = gdash_ask.ask(p, "sales", "draft", rec, "how many orders?",
                         model_double.failing("the model could not be reached"), {})
    s = gdash_test.ok(s, not down.ok, "an unreachable model is not a crash")
    s = gdash_test.eq(s, down.stage, "model", "it stops at the model stage")
    s = gdash_test.contains_text(s, down.message, "could not be reached", "carrying the reason")

    ' --- model profiles ----------------------------------------------------
    ' A ROOT WITH NO MODELS FILE, owned by this assertion. Reading the shared
    ' root worked only while nothing had written one yet -- so on a second run
    ' into the same directory it failed, which is the assertion admitting it
    ' was testing the directory rather than the code. The same trap as the
    ' cold-start one above, found the same way.
    bare = gdash_paths.roles(root + "/nomodels")
    none = gdash_ask.model_profile(bare, "")
    s = gdash_test.ok(s, not none.ok, "no models file configured is not an error")
    s = gdash_test.contains_text(s, none.message, "models.json", "and it names the file to write")

    made = gdash_paths.ensure_dir(p.config_dir)
    mf {file} = gdash_paths.models_file(p)
    write(mf, encode({ default: "house", house: { provider: "anthropic", model: "claude-not-a-real-model", key: "sk-fake-not-a-key" } }))

    got = gdash_ask.model_profile(p, "")
    s = gdash_test.ok(s, got.ok, "the default profile is found")
    s = gdash_test.eq(s, got.name, "house", "by the name `default` points at")
    s = gdash_test.eq(s, string(got.profile["model"]), "claude-not-a-real-model", "with its model")

    named = gdash_ask.model_profile(p, "house")
    s = gdash_test.ok(s, named.ok, "and by name")
    missing = gdash_ask.model_profile(p, "elsewhere")
    s = gdash_test.ok(s, not missing.ok, "a profile that is not there is refused by name")
    s = gdash_test.contains_text(s, missing.message, "elsewhere", "saying which one")

    ' A KEY MUST NOT TRAVEL WITH THE ANSWER. The draft is rendered into a page
    ' and could be logged; nothing in it may carry the credential.
    s = gdash_test.ok(s, not contains(string(good), "sk-fake-not-a-key"), "no key reaches the draft")
    s = gdash_test.ok(s, not contains(string(money.notes), "sk-fake-not-a-key"), "nor the unit notes")

    ' --- requalifying, which is where the two tiers disagree ---------------
    '
    ' The NLQ catalog names a table `orders.orders`, because every dataset is
    ' attached under its own name and that is what makes each `_gdash_meta`
    ' readable at its own scale. A VISUAL query opens its dataset directly and
    ' attaches only the siblings, so the same table is plain `orders` and
    ' `orders.orders` does not resolve at all. A promoted query has to cross
    ' that line.
    ds = ["orders", "regions"]
    s = gdash_test.eq(s, gdash_ask.requalify("select count(*) as n from orders.orders", ds),
                      "select count(*) as n from orders", "the schema-qualified table becomes the table")
    s = gdash_test.eq(s, gdash_ask.requalify("select 1 from orders.orders where orders.orders.amount > 1000", ds),
                      "select 1 from orders where orders.amount > 1000", "and a three-part column becomes a two-part one")
    s = gdash_test.eq(s, gdash_ask.requalify("select * from orders.orders o join regions.regions r on o.region = r.region", ds),
                      "select * from orders o join regions r on o.region = r.region", "every dataset, not just the first")
    s = gdash_test.eq(s, gdash_ask.requalify("select * from myorders.orders", ds),
                      "select * from myorders.orders", "a name that merely ends in a dataset name is left alone")
    s = gdash_test.eq(s, gdash_ask.requalify("select 1 where x = 'orders.orders'", ds),
                      "select 1 where x = 'orders.orders'", "and one inside a string literal is not SQL")
    s = gdash_test.eq(s, gdash_ask.requalify("select ORDERS.ORDERS.amount from ORDERS.ORDERS", ds),
                      "select ORDERS.amount from ORDERS", "SQL identifiers are case-insensitive and models shout")
    s = gdash_test.eq(s, gdash_ask.requalify("select orders.amount from orders", ds),
                      "select orders.amount from orders", "an already-qualified column is untouched")

    ' --- the encoding a draft suggests -------------------------------------
    s = gdash_test.eq(s, gdash_ask.suggest_encoding([{ n: 3 }]).mark, "value", "one row one column is a figure")
    s = gdash_test.eq(s, gdash_ask.suggest_encoding([{ region: "west", total: 3 }]).mark, "bar", "a label and a number is a bar")
    s = gdash_test.eq(s, gdash_ask.suggest_encoding([{ region: "west", total: 3 }]).x, "region", "with the label on x")
    s = gdash_test.eq(s, gdash_ask.suggest_encoding([{ a: 1, b: 2, c: 3 }]).mark, "table", "anything else is a table")
    s = gdash_test.eq(s, gdash_ask.suggest_encoding([]).mark, "table", "and no rows is a table, not a crash")

    ' --- the visual a draft would become -----------------------------------
    grouped = gdash_ask.ask(p, "sales", "draft", rec, "total by region",
                            model_double.saying("select region, sum(amount) as total from orders.orders group by region"), {})
    s = gdash_test.ok(s, grouped.ok, "a grouped question answers")
    vis = gdash_ask.draft_visual(grouped, rec, grouped.scaled)
    s = gdash_test.eq(s, vis.dataset, "orders", "the visual opens the dataset the query names")
    s = gdash_test.eq(s, vis.sql, "select region, sum(amount) as total from orders group by region", "with the query requalified")
    s = gdash_test.eq(s, vis.encoding.mark, "bar", "and an encoding that suits the shape")

    ' A query touching only the SECOND dataset must open the second. Without
    ' this case, "always take the first dataset" passes every assertion above,
    ' because `orders` happens to sort first -- which is exactly what the
    ' mutation run found.
    ' The question has to GROUND the second dataset, not merely be about it:
    ' "who manages the west?" grounds `orders` alone, because `west` is one of
    ' its own values, and check_sql then correctly refuses a query naming a
    ' table nobody offered. `manager` is a column only regions has.
    who = gdash_ask.ask(p, "sales", "draft", rec, "list every manager",
                        model_double.saying("select manager from regions.regions where region = 'west'"), {})
    s = gdash_test.ok(s, who.ok, "a question about the other dataset answers")
    vis2 = gdash_ask.draft_visual(who, rec, who.scaled)
    s = gdash_test.eq(s, vis2.dataset, "regions", "and its visual opens THAT dataset, not the first one")
    s = gdash_test.eq(s, vis2.sql, "select manager from regions where region = 'west'", "requalified the same way")

    ' --- money, one step later than step 0 ---------------------------------
    '
    ' A money column holds minor units, and an aggregate of minor units is
    ' still minor units. A promoted `sum(amount) as total` renders 215100 where
    ' a person expects $2,151.00 -- the same failure as step 0, arriving in the
    ' chart instead of the answer. gdash can render it correctly, but only if
    ' the encoding says the channel is currency.
    sc = grouped.scaled
    s = gdash_test.ok(s, gdash_ask.is_money_channel("select region, sum(amount) as total from orders group by region", sc, "total"), "an aggregate over a money column carries money")
    s = gdash_test.ok(s, gdash_ask.is_money_channel("select region, avg(orders.amount) as total from orders", sc, "total"), "whatever the aggregate, and however the column is qualified")
    s = gdash_test.ok(s, gdash_ask.is_money_channel("select amount from orders", sc, "amount"), "and so does the column itself, unaliased")

    ' NOT marking is the safe direction, and these are the cases that must not
    ' be marked. A count rendered as currency would show 3 as $0.03 -- a wrong
    ' answer produced by the machinery meant to prevent wrong answers.
    s = gdash_test.ok(s, not gdash_ask.is_money_channel("select region, count(*) as n from orders where amount > 100000 group by region", sc, "n"), "a count in a query full of money is not money")
    s = gdash_test.ok(s, not gdash_ask.is_money_channel("select region, amount / 100 as dollars from orders", sc, "dollars"), "an expression that already converted is left alone")
    s = gdash_test.ok(s, not gdash_ask.is_money_channel("select region, sum(amount) as total from orders", sc, "region"), "and a label channel is never money")
    ' THE SHARP ONE: `count(amount)` counts rows, it does not add money. Only
    ' the aggregate NAME separates it from `sum(amount)`, so without that check
    ' a count of a money column renders as a currency and every other case here
    ' still passes.
    s = gdash_test.ok(s, not gdash_ask.is_money_channel("select region, count(amount) as n from orders group by region", sc, "n"), "counting a money column counts rows, not money")
    s = gdash_test.ok(s, not gdash_ask.is_money_channel("select region, length(amount) as n from orders", sc, "n"), "and a function that is not an aggregate says nothing about units")

    s = gdash_test.eq(s, string(vis.encoding["format"]), "currency", "so the promoted visual formats its money channel")
    s = gdash_test.eq(s, string(vis.encoding["currency"]), "USD", "in the currency the record declares")

    counted = gdash_ask.ask(p, "sales", "draft", rec, "how many orders per region?",
                            model_double.saying("select region, count(*) as n from orders.orders group by region"), {})
    cvis = gdash_ask.draft_visual(counted, rec, counted.scaled)
    s = gdash_test.ok(s, is_unknown(cvis.encoding["format"]), "a count is promoted with no currency format at all")

    ' --- promotion must not produce a visual that cannot draw ---------------
    '
    ' GDASH-12 set `format: "currency"` whenever the value channel aggregated a
    ' money column, without asking whether the renderer could find a SCALE for
    ' it. On a multi-currency dashboard that promotes a visual which validates,
    ' promotes, and then renders an error instead of a chart -- discovered by
    ' whoever opens the dashboard rather than by whoever promoted it (G13-4).
    made = gdash_paths.ensure_dir(gdash_paths.data_dir(p, "treasury", "draft"))
    tcols = ["account", "usd_value", "jpy_value"]
    trows = [["ACC-1", "1250750.25", "430000"], ["ACC-2", "-90425.10", "12"]]
    tplan = gdash_store.plan_columns(tcols, trows, { usd_value: { type: "money", scale: 2 },
                                                    jpy_value: { type: "money", scale: 0 } })
    tm = gdash_store.materialize(gdash_paths.dataset_db(p, "treasury", "draft", "positions"), "positions", tplan, trows)
    s = gdash_test.ok(s, tm.ok, "a two-currency dataset materializes")

    trec = { datasets: {} }
    trec["datasets"]["positions"] = { columns: {} }
    trec["datasets"]["positions"]["columns"]["usd_value"] = { type: "money", scale: 2, currency: "USD" }
    trec["datasets"]["positions"]["columns"]["jpy_value"] = { type: "money", scale: 0, currency: "JPY" }

    mixed = gdash_ask.ask(p, "treasury", "draft", trec, "total usd value by account",
                          model_double.saying("select account, sum(usd_value) as total from positions.positions group by account"), {})
    s = gdash_test.ok(s, mixed.ok, "the question answers")
    mvis = gdash_ask.draft_visual(mixed, trec, mixed.scaled)
    s = gdash_test.ok(s, is_unknown(mvis.encoding["format"]), "an unresolvable money channel is NOT promoted as currency")
    caveat = gdash_ask.currency_caveat(mixed, trec, mvis)
    s = gdash_test.contains_text(s, caveat, "total", "and the draft says which column")
    s = gdash_test.contains_text(s, caveat, "minor units", "and what will happen instead")
    s = gdash_test.contains_text(s, caveat, "Alias it", "and what to do about it")

    ' Aliased to the money column's own name, it resolves, and the currency
    ' format comes back -- which is exactly what the caveat tells a person.
    named = gdash_ask.ask(p, "treasury", "draft", trec, "total usd value by account",
                          model_double.saying("select account, sum(usd_value) as usd_value from positions.positions group by account"), {})
    nvis = gdash_ask.draft_visual(named, trec, named.scaled)
    s = gdash_test.eq(s, string(nvis.encoding["format"]), "currency", "aliased to the money column, it formats as currency")
    s = gdash_test.eq(s, gdash_ask.currency_caveat(named, trec, nvis), "", "and there is nothing left to warn about")

    ' The single-currency case is unchanged: `total` is not a money column, but
    ' every money column in reach agrees, so there is nothing to be wrong about.
    s = gdash_test.eq(s, string(vis.encoding["format"]), "currency", "a single-currency dashboard still formats an aliased aggregate")

    ' --- promoting it into the record --------------------------------------
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "sales"))
    rf {file} = gdash_paths.record_file(p, "sales")
    write(rf, encode({ format: 1, name: "sales",
                       datasets: { orders: { profile: "fake", sql: "select 1" },
                                   regions: { profile: "fake", sql: "select 1" } },
                       params: {}, visuals: {}, tabs: [{ name: "Sales", layout: { vert: [] } }] }))

    done = gdash_ask.promote(p, "sales", "total_by_region", vis)
    s = gdash_test.ok(s, done.ok, "the draft promotes: " + done.message)

    back = gdash_record.load_file(gdash_paths.record_file(p, "sales"))
    s = gdash_test.ok(s, back.ok, "and the record still validates: " + join(back.errors, "; "))
    s = gdash_test.eq(s, visual_sql(back.record, "total_by_region"), vis.sql, "the visual is in the record")
    ' A visual in `visuals` that no tab names renders nowhere, which would be a
    ' promotion that appeared to work.
    s = gdash_test.eq(s, first_leaf(back.record), "total_by_region", "and on the first tab, where it will be seen")

    again = gdash_ask.promote(p, "sales", "total_by_region", vis)
    s = gdash_test.ok(s, not again.ok, "promoting over an existing visual is refused")
    s = gdash_test.contains_text(s, again.message, "already has", "by name")

    unnamed = gdash_ask.promote(p, "sales", "   ", vis)
    s = gdash_test.ok(s, not unnamed.ok, "a promoted visual needs a name")

    ' A visual gdash would refuse to load must not reach the file: the record
    ' that stops rendering is the whole dashboard, and the draft that caused it
    ' would be gone by then.
    bad = gdash_ask.promote(p, "sales", "broken", { dataset: "nosuch", sql: "select 1", encoding: { mark: "table" } })
    s = gdash_test.ok(s, not bad.ok, "a visual that would not validate is refused")
    s = gdash_test.contains_text(s, bad.message, "validate", "saying so")
    after = gdash_record.load_file(gdash_paths.record_file(p, "sales"))
    s = gdash_test.ok(s, after.ok, "and the record on disk is untouched")
    s = gdash_test.ok(s, is_unknown(after.record["visuals"]["broken"]), "the refused visual was never written")

    absent = gdash_ask.promote(p, "nosuchdashboard", "v", vis)
    s = gdash_test.ok(s, not absent.ok, "promoting into a dashboard that is not there is refused")

    exit(gdash_test.report(s))
end program

' A promoted visual's SQL, or a legible absence. Indexing it inline RAISED
' when a mutation stopped the write -- `visuals` is then an empty record, and
' the second index lands on `unknown`.
function visual_sql(record, id)
    on error goto next
    vis = record["visuals"]
    if is_unknown(vis) or type(vis) != "record" then
        return "(no visuals)"
    end if
    one = vis[id]
    if is_unknown(one) or type(one) != "record" then
        return "(not promoted)"
    end if
    got = string(one["sql"])
    if error then
        return "(no sql)"
    end if
    return got
end function

' The promoted visual's place on the first tab, or a legible absence. Reading
' it inline RAISED when a mutation removed the placement, which killed the run
' and hid every assertion after it -- the same failure the nlq suite had.
function first_leaf(record)
    on error goto next
    tabs = record["tabs"]
    if is_unknown(tabs) or type(tabs) != "array" or count(tabs) = 0 then
        return "(no tabs)"
    end if
    kids = tabs[0]["layout"]["vert"]
    if is_unknown(kids) or type(kids) != "array" or count(kids) = 0 then
        return "(nothing on the first tab)"
    end if
    got = string(kids[0]["visual"])
    if error then
        return "(not a visual leaf)"
    end if
    return got
end function

' Indexed reads go through this, so a failed count assertion does not then
' crash the run and hide every assertion after it.
function note_at(listv, i)
    if i < count(listv) then
        return listv[i]
    end if
    return { means: "(no note)", literal: "(no note)", column: "(no note)", dataset: "(no note)" }
end function
