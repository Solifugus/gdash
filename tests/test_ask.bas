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

    s = gdash_test.suite("ask")
    root = args[0]
    p = gdash_paths.roles(root)

    rec = { datasets: {} }
    rec["datasets"]["orders"] = { columns: {} }
    rec["datasets"]["orders"]["columns"]["amount"] = { type: "money", scale: 2, currency: "USD" }
    rec["datasets"]["regions"] = {}

    ' --- nothing refreshed yet ---------------------------------------------
    cold = gdash_ask.ask(p, "sales", "draft", rec, "how many orders?", model_double.saying("select 1"), {})
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

    ' --- what the model can do wrong ---------------------------------------
    del = gdash_ask.ask(p, "sales", "draft", rec, "remove the west orders",
                        model_double.saying("delete from orders.orders where region = 'west'"), {})
    s = gdash_test.ok(s, not del.ok, "a write is refused")
    s = gdash_test.eq(s, del.stage, "sql", "by the SQL check, before anything runs")
    s = gdash_test.ok(s, count(del.problems) > 0, "with a problem to show")
    s = gdash_test.eq(s, del.sql, "delete from orders.orders where region = 'west'", "and the query it refused")

    stranger = gdash_ask.ask(p, "sales", "draft", rec, "how many payroll runs?",
                             model_double.saying("select count(*) from payroll.payroll"), {})
    s = gdash_test.ok(s, not stranger.ok, "a query naming a table that is not there is refused")
    s = gdash_test.eq(s, stranger.stage, "sql", "also by the SQL check")

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
    none = gdash_ask.model_profile(p, "")
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

    exit(gdash_test.report(s))
end program

' Indexed reads go through this, so a failed count assertion does not then
' crash the run and hide every assertion after it.
function note_at(listv, i)
    if i < count(listv) then
        return listv[i]
    end if
    return { means: "(no note)", literal: "(no note)", column: "(no note)", dataset: "(no note)" }
end function
