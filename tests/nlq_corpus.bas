' The numbers `nlq_for_gdash.md` asks for, as far as they can be measured
' without spending money.
'
' TWO TIERS, because they need different things.
'
' THE GROUNDING TIER is hermetic and runs in the ordinary suite. `nlq.plan`
' does no I/O: it grounds a question against the catalog and either produces a
' prompt or refuses with candidates. So "how often does gdash's own catalog let
' a reasonable question through, and how often does it refuse one it should
' have answered" is measurable with no model at all, and it is the half gdash
' is actually responsible for -- the catalog, the vocabulary and the values are
' gdash's to supply.
'
' THE ANSWER TIER needs a real model and is gated on GDASH_NLQ_TEST=1 with a
' configured profile. It is not in the suite and never will be: it costs money,
' it needs the network, and its result is a distribution rather than a pass.
'
' Each question declares what SHOULD happen, so a refusal is scored against
' intent rather than counted. `ground` means the catalog should settle it;
' `refuse` means it genuinely is ambiguous or unanswerable and a refusal is the
' RIGHT answer, not a miss.

program main(args)
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_record from "../src/gdash_record.bas"
    load gdash_store from "../src/gdash_store.bas"
    load gdash_nlq from "../src/gdash_nlq.bas"
    load gdash_ask from "../src/gdash_ask.bas"
    load model_double from "model_double.bas"
    load nlq

    root = args[0]
    dash = "sales"
    if count(args) > 1 then
        dash = args[1]
    end if
    p = gdash_paths.roles(root)
    loaded = gdash_record.load_file(gdash_paths.record_file(p, dash))
    if not loaded.ok then
        print to error "cannot read the record: " + join(loaded.errors, "; ")
        exit(2)
    end if
    rec = loaded.record

    db = gdash_paths.stage_db(p, dash, "draft")
    desc = gdash_store.describe_datasets(db)
    if not desc.ok or count(keys(desc.datasets)) = 0 then
        print to error "no dataset of " + dash + " has been refreshed; there is nothing to ground against"
        exit(2)
    end if
    cat = gdash_nlq.catalog(desc)
    rows = gdash_ask.value_rows(db, desc, 25)
    vocab = nlq.vocabulary(rows, { max_values: 25 })
    ex = nlq.exemplars(rows, { min_distinct: 2 })

    ' The corpus. Deliberately mixed: plain questions, questions that need the
    ' second dataset, questions that turn on a value rather than a column, and
    ' questions that SHOULD be refused.
    corpus = [
        { q: "how many orders are there?",                       want: "ground" },
        { q: "what is the total amount?",                        want: "ground" },
        { q: "total amount by region",                           want: "ground" },
        { q: "how many orders were over 1000 dollars?",          want: "ground" },
        { q: "what did the west region sell?",                   want: "ground" },
        { q: "list every manager",                               want: "ground" },
        { q: "which manager covers the north?",                  want: "ground" },
        { q: "total amount by month",                            want: "ground" },
        { q: "how many orders in january 2026?",                 want: "ground" },
        { q: "what is the largest order amount?",                want: "ground" },
        { q: "what is the average order amount by region?",      want: "ground" },
        { q: "how many regions are there?",                      want: "ground" },
        { q: "which region sold the most?",                      want: "ground" },
        { q: "show the amount for each month in the east",       want: "ground" },
        { q: "count the orders per manager",                     want: "ground" },
        ' Nothing in this dashboard knows about any of these. A refusal is the
        ' right answer and a confident SQL query is the wrong one.
        { q: "how many employees do we have?",                   want: "refuse" },
        { q: "what is the share price?",                         want: "refuse" },
        { q: "how many support tickets were opened last week?",  want: "refuse" },
        { q: "what is our profit margin?",                       want: "refuse" },
        { q: "who is the chief executive?",                      want: "refuse" }
    ]

    ' Four counters, not two minus one: the first draft computed the refusal
    ' figure by subtraction and printed -10, which is the kind of arithmetic
    ' that makes a report worse than no report.
    ground_hit = 0
    ground_miss = 0
    refuse_hit = 0
    refuse_miss = 0
    want_ground = 0
    want_refuse = 0
    misses = []
    i = 0
    while i < count(corpus)
        c = corpus[i]
        if c.want = "ground" then
            want_ground += 1
        else
            want_refuse += 1
        end if
        ' THROUGH GDASH'S OWN PIPELINE, not through `nlq` directly. The first
        ' version of this called `nlq.plan` and `nlq.check_answerable` itself,
        ' which measured the LIBRARY -- and so it scored 20/20 with gdash's own
        ' answerability check mutated away. A corpus that cannot fail when the
        ' thing it is about is removed is a corpus measuring the wrong thing.
        '
        ' The model is a double saying something useless, because this tier is
        ' only asking WHETHER GDASH WOULD HAVE CALLED A MODEL AT ALL. Any stage
        ' past `ground` means it would have.
        d = gdash_ask.ask(p, dash, "draft", rec, c.q, model_double.saying("select 1"), {})
        settled = d.stage != "ground"
        why = ""
        if not settled then
            why = " (" + d.message + ")"
        end if

        if c.want = "ground" then
            if settled then
                ground_hit += 1
            else
                ground_miss += 1
                misses = concat(misses, ["refused, should have grounded: " + c.q + why])
            end if
        else
            if settled then
                refuse_miss += 1
                misses = concat(misses, ["grounded, should have refused: " + c.q])
            else
                refuse_hit += 1
            end if
        end if
        i += 1
    end while

    print("nlq corpus, grounding tier -- " + string(count(corpus)) + " questions, no model")
    print("  answerable questions grounded:  " + string(ground_hit) + "/" + string(want_ground))
    print("  unanswerable questions refused: " + string(refuse_hit) + "/" + string(want_refuse))
    print("  vocabulary columns offered:     " + string(count(keys(vocab))))
    print("  exemplar columns offered:       " + string(count(keys(ex))))
    print("  tables in the catalog:          " + string(count(cat.tables)))
    i = 0
    while i < count(misses)
        print("  . " + misses[i])
        i += 1
    end while

    ' --- the answer tier ----------------------------------------------------
    '
    ' Gated, because it costs money and needs the network. It runs the WHOLE
    ' pipeline through whatever model the root's models.json configures, and
    ' reports what came back: a query that ran, a query that was refused, a
    ' model that could not be reached. It scores CORRECTNESS OF SHAPE, not of
    ' value -- nobody here knows the right answer to "which region sold the
    ' most" except by running a query, which is the thing being tested.
    '
    ' The unit notes are counted separately and on purpose. A question about
    ' money that produced a query with no note on it is the step-0 failure
    ' with nothing standing between it and a person.
    live = string(default(env("GDASH_NLQ_TEST"), ""))
    if live = "1" then
        prof = gdash_ask.model_profile(p, "")
        if not prof.ok then
            print to error prof.message
            exit(2)
        end if
        wire = gdash_ask.live_model(prof.profile)
        answered = 0
        stopped = {}
        noted = 0
        money_qs = 0
        j = 0
        while j < count(corpus)
            c = corpus[j]
            d = gdash_ask.ask(p, dash, "draft", rec, c.q, wire, {})
            if d.ok then
                answered += 1
                if contains(lower(c.q), "dollar") or contains(lower(c.q), "amount") then
                    money_qs += 1
                    if count(d.notes) > 0 then
                        noted += 1
                    end if
                end if
                print("  + " + c.q)
                print("      " + d.sql)
            else
                if is_unknown(stopped[d.stage]) then
                    stopped[d.stage] = 0
                end if
                stopped[d.stage] = stopped[d.stage] + 1
                print("  - " + c.q + "  [" + d.stage + "] " + d.message)
            end if
            j += 1
        end while
        print("")
        print("nlq corpus, answer tier -- " + string(count(corpus)) + " questions, through " + string(prof.name))
        print("  produced a query that ran: " + string(answered) + "/" + string(count(corpus)))
        for each st in sort(keys(stopped))
            print("  stopped at " + st + ": " + string(stopped[st]))
        next
        print("  money questions with a unit note: " + string(noted) + "/" + string(money_qs))
    end if

    ' A floor, not a target. This exists so that a change to the catalog, the
    ' vocabulary or the sampling shows up as a number rather than as nobody
    ' noticing -- and the floor is deliberately below where it stands, because
    ' a corpus that must score perfectly is a corpus somebody edits instead of
    ' fixing the thing it measured.
    floor = 12
    if ground_hit < floor then
        print to error "GROUNDING FELL: " + string(ground_hit) + " of " + string(want_ground) + " answerable questions grounded, floor is " + string(floor)
        exit(1)
    end if
    ' THIS FLOOR IS THE REGRESSION THAT ACTUALLY HAPPENED. Before
    ' check_answerable was wired in, all five unanswerable questions planned
    ' `ok` and would have been sent to a model and paid for. A refusal floor is
    ' the only thing that would have noticed.
    refuse_floor = 4
    if refuse_hit < refuse_floor then
        print to error "REFUSAL FELL: " + string(refuse_hit) + " of " + string(want_refuse) + " unanswerable questions refused, floor is " + string(refuse_floor)
        print to error "  a question the catalog cannot answer must not reach a model"
        exit(1)
    end if
    exit(0)
end program
