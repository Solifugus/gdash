' gdash — asking a dashboard's data a question in English.
'
' The library is `nlq` and this is the part `nlq` deliberately does not do. It
' performs no I/O: it builds a prompt, checks what comes back, and settles an
' answer against rows somebody else fetched. Everything it cannot do -- the
' catalog, the vocabulary, the model call, running the SQL, and knowing that an
' integer is cents -- is gdash's.
'
' WHAT THIS PRODUCES IS A DRAFT, NOT AN ANSWER (nlq_contribution.md §6). A
' question yields the generated SQL, the assumptions behind it, the `data as
' of` it read, the unit notes, and the rows -- for a person to look at and
' promote into the dashboard, where it is versioned, diffed and audited like
' every other visual. A wrong query is caught while it is still a draft, by
' somebody who can read SQL. Nothing here writes a record.
'
' SO THE DASHBOARD NEVER RE-ASKS. Promotion stores the SQL, not the question,
' which is why gdash needs no answer cache on the serving path despite a
' question costing 17-60 seconds of model time. `nlq` supplies `plan.key` for
' one anyway; the only caller who would benefit is a person re-asking the same
' words in the drafting UI, and that is not worth a cache yet.
'
' THE SEAM. Everything that reaches a model goes through a record of function
' values, exactly as gdash_auth_ldap takes a `wire` and gdash_session takes a
' store:
'
'   wire = { ctx, complete: fn(ctx, system, user) -> { ok, text, reason } }
'
' The live implementation is `wire_complete` over stdlib `llm`; a scripted
' model in tests/ is the other. The whole pipeline -- refusal handling, a model
' that returns prose instead of SQL, SQL that does not compile, a question
' about a dataset that has never refreshed -- is then hermetic, which matters
' more here than for LDAP: a real model cannot be made to return the same
' wrong thing twice.

library gdash_ask

    load gdash_paths from "gdash_paths.bas"
    load gdash_store from "gdash_store.bas"
    load gdash_nlq from "gdash_nlq.bas"
    load gdash_sched from "gdash_sched.bas"
    load gdash_record from "gdash_record.bas"
    load gdash_format from "gdash_format.bas"
    load gdash_limits from "gdash_limits.bas"
    load gdash_spend from "gdash_spend.bas"
    load nlq

    ' --- the model profile -------------------------------------------------
    '
    ' Server-level, never in a dashboard record, for the same reason a
    ' connection profile is not (design §2, §8): a record is authored, diffed
    ' and published, and a key in one would be a key in the publication
    ' history. The file is the operator's, read at 0600 by the same convention
    ' as connections.
    '
    ' A KEY MAY BE NAMED RATHER THAN WRITTEN. `key_env` names an environment
    ' variable, which is what a systemd unit with an EnvironmentFile wants;
    ' `key` in the file is what a single-machine install wants. Neither ever
    ' reaches argv, a record, the audit log or a rendered page.

    function load_models(p)
        path = gdash_paths.models_file(p)
        on error goto next
        f {file} = path
        if error then
            return {}
        end if
        if not exists(f) then
            return {}
        end if
        parsed = try_decode(read(f))
        if error or not parsed.ok then
            return {}
        end if
        if type(parsed.value) != "record" then
            return {}
        end if
        return parsed.value
    end function

    ' The named profile, or a refusal that names the file to put it in. A
    ' missing model is an ordinary configuration state, not an error: gdash
    ' serves dashboards perfectly well without one, and only this feature
    ' stops.
    function model_profile(p, name)
        models = load_models(p)
        want = trim(string(name))
        if want = "" then
            want = string(default(models["default"], ""))
        end if
        if want = "" then
            ks = keys(models)
            i = 0
            while i < count(ks)
                if ks[i] != "default" then
                    want = ks[i]
                    i = count(ks)
                else
                    i += 1
                end if
            end while
        end if
        if want = "" then
            return { ok: false, name: "", profile: {},
                     message: "no model profile is configured; define one in " + gdash_paths.models_file(p) }
        end if
        got = models[want]
        if is_unknown(got) or type(got) != "record" then
            return { ok: false, name: want, profile: {},
                     message: "no model profile named '" + want + "' in " + gdash_paths.models_file(p) }
        end if
        return { ok: true, name: want, profile: got, message: "" }
    end function

    ' --- the wire ----------------------------------------------------------

    ' `load llm` is inside the function rather than at the library level, for
    ' the reason gdash_auth_ldap keeps `load ldap` inside its own: a gdash that
    ' never asks a question should not fail to start because a library it never
    ' calls is missing.
    function wire_complete(ctx, system, user)
        on error goto next
        load llm
        if error then
            return { ok: false, text: "", reason: "the llm library is not available" }
        end if
        m = _model_handle(ctx)
        if is_unknown(m) then
            return { ok: false, text: "", reason: "the model profile is not usable" }
        end if
        ' `chat` rather than `ask`, for the usage: what a question cost is
        ' counted against the site's model budget (GDASH-16).
        r = llm.chat(m, system, [{ role: "user", content: user }])
        if error then
            ' llm RAISES on transport and provider failure, including auth
            ' rejection and 429/5xx after its retry budget. A raise inside a
            ' request handler kills the worker (PLAT-WEB, let-it-crash), so it
            ' stops here and becomes a value like every other outcome.
            return { ok: false, text: "", reason: "the model could not be reached" }
        end if
        usage = r.usage
        if is_unknown(r.text) then
            ' An empty completion is llm's `unknown`, and it is not an error:
            ' the model was reached and said nothing useful -- and was paid.
            return { ok: false, text: "", reason: "the model returned nothing", usage: usage }
        end if
        return { ok: true, text: string(r.text), reason: "", usage: usage }
    end function

    ' A profile is a record, so the handle is built rather than stored. The key
    ' is fetched here and nowhere else, and it is never returned, printed or
    ' put in a record -- `_model_handle` is the only function in gdash that
    ' holds one.
    function _model_handle(profile)
        on error goto next
        load llm
        if error then
            return unknown
        end if
        provider = trim(string(default(profile["provider"], "anthropic")))
        model = trim(string(default(profile["model"], "")))
        if model = "" then
            return unknown
        end if
        key = _model_key(profile)
        if provider = "offline" then
            ' THE PLATFORM'S OWN FIXTURE TRANSPORT, not a test-only hook: an
            ' operator installing gdash can verify the whole path -- profile,
            ' catalog, prompt, SQL check, unit notes, promotion -- without a
            ' key, a network, or a token spent. `llm.offline` reads
            ' <dir>/<format>_response.json, so what it returns is whatever the
            ' deployment put there.
            dir = trim(string(default(profile["offline_dir"], "")))
            if dir = "" then
                return unknown
            end if
            m = llm.offline(llm.anthropic(model, ""), dir)
        else if provider = "local" then
            base = trim(string(default(profile["base_url"], "")))
            if base = "" then
                return unknown
            end if
            m = llm.local(base, model)
        else if provider = "openai" then
            m = llm.openai(model, key)
        else
            m = llm.anthropic(model, key)
        end if
        if error then
            return unknown
        end if
        if not is_unknown(profile["max_tokens"]) then
            m["max_tokens"] = number(profile["max_tokens"])
        end if
        if not is_unknown(profile["timeout"]) then
            m["timeout"] = number(profile["timeout"])
        end if
        ' Temperature 0 is llm's default and the right one here: the same
        ' question against the same data should not produce a different query
        ' each time somebody asks, because a person reviewing a draft is
        ' entitled to reproduce it.
        return m
    end function

    function _model_key(profile)
        named = trim(string(default(profile["key_env"], "")))
        if named != "" then
            got = env(named)
            if not is_unknown(got) then
                return string(got)
            end if
            return ""
        end if
        return string(default(profile["key"], ""))
    end function

    function live_model(profile)
        return { ctx: profile, complete: gdash_ask.wire_complete }
    end function

    ' --- what gdash tells the model about its own data ---------------------

    ' Vocabulary rows, from the values gdash actually holds. Text columns only:
    ' a number's spellings teach nothing, and an amount's teach less.
    '
    ' `nlq.vocabulary` drops any column with more values than its cap, which is
    ' the right behaviour and means gdash can sample generously: a partial list
    ' would be worse than none, because a literal absent from it reads as
    ' unknown rather than merely unlisted.
    function value_rows(db, desc, cap)
        rows = []
        dsn = sort(keys(desc.datasets))
        i = 0
        while i < count(dsn)
            ds = dsn[i]
            cols = desc.datasets[ds].columns
            j = 0
            while j < count(cols)
                if cols[j].kind = "text" then
                    vals = gdash_store.sample_column(db, ds, cols[j].name, cap + 1)
                    if count(vals) > 0 then
                        rows = concat(rows, [{ schema: "", table: ds, column: cols[j].name, values: vals }])
                    end if
                end if
                j += 1
            end while
            i += 1
        end while
        return rows
    end function

    ' When each dataset the question can reach was last refreshed, as one line
    ' per dataset. The draft carries it because a promoted visual will carry
    ' it, and because an answer about data from last Tuesday is a different
    ' answer (design §4).
    function as_of(p, name, mode, names)
        out = []
        dsn = sort(names)
        i = 0
        while i < count(dsn)
            st = gdash_sched.read_state(gdash_paths.dataset_state(p, name, mode, dsn[i]))
            out = concat(out, [{ dataset: dsn[i], at: st.last_success, text: gdash_format.when(st.last_success) }])
            i += 1
        end while
        return out
    end function

    ' --- the pipeline ------------------------------------------------------
    '
    ' Every exit is a VALUE with the same shape, because every one of them has
    ' to be rendered to a person who asked a question and is owed a reason:
    '
    '   { ok, stage, question, message, candidates, sql, problems, notes,
    '     rows, answer, tables, key, as_of }
    '
    ' `stage` names where it stopped -- "data", "ground", "model", "sql",
    ' "run", "answered" -- so the UI can say "no data has been refreshed yet"
    ' rather than "something went wrong", and so a test can assert WHERE a
    ' pipeline stopped rather than only that it did.

    function _stop(stage, question, message, extra)
        base = { ok: false, stage: stage, question: question, message: message,
                 candidates: [], sql: "", problems: [], notes: [], rows: [],
                 answer: unknown, tables: [], key: "", as_of: [], scaled: {},
                 units_told: false }
        for each k in keys(extra)
            base[k] = extra[k]
        next
        return base
    end function

    ' Which refusal this is, in words a person can act on. `nothing_grounded`
    ' carries the words that reached nothing, which is the useful half.
    function _refusal_words(plan)
        ' `nothing` is a gBASIC keyword (SQL NULL maps to it), so this is
        ' `unmatched`. The parse error named the line, which is the good kind.
        unmatched = false
        words = []
        for each r in plan.refused_because
            if type(r) = "record" and string(default(r["kind"], "")) = "nothing_grounded" then
                unmatched = true
                if type(r["candidates"]) = "array" then
                    words = r["candidates"]
                end if
            end if
        next
        if not unmatched then
            return "that could mean more than one thing"
        end if
        if count(words) > 0 then
            return "this dashboard has no data that could answer that: nothing here matches " + join(words, ", ")
        end if
        return "this dashboard has no data that could answer that"
    end function

    function ask(p, name, mode, rec, question, wire, options)
        q = trim(string(question))
        if q = "" then
            return _stop("ground", q, "ask a question", {})
        end if

        ' Only datasets that have refreshed: a question cannot be answered
        ' from a table that does not exist, and offering its name would be
        ' offering a table whose columns are a guess.
        db = gdash_paths.stage_db(p, name, mode)
        desc = gdash_store.describe_datasets(db)
        if not desc.ok or count(keys(desc.datasets)) = 0 then
            return _stop("data", q, "no dataset of this dashboard has been refreshed yet, so there is nothing to ask about", {})
        end if

        stamps = as_of(p, name, mode, keys(desc.datasets))
        cat = gdash_nlq.catalog(desc)
        scaled = gdash_nlq.scaled_columns(desc, rec)

        rows = value_rows(db, desc, 25)
        vocab = nlq.vocabulary(rows, { max_values: 25 })
        ex = nlq.exemplars(rows, { min_distinct: 2 })

        ' THE UNIT NOTES GO TO THE MODEL, not only to the reviewer. Until
        ' 2026-09-14 there was no channel for them and the whole defence was
        ' the note beside the draft; `nlq.plan` now takes `notes`, so the
        ' model is told before it writes rather than the reader afterwards.
        '
        ' AN OLDER `nlq` RAISES on an unknown option, and gdash must still run
        ' against one -- the stdlib is installed separately from the
        ' interpreter, and the two move apart routinely (S0-1 was exactly
        ' that). So this tries with the notes and falls back without them,
        ' ONCE, and records which happened. A silent fallback would hide the
        ' very hazard the notes exist to close, so `units_told` travels with
        ' the draft and the UI says so.
        ' Named `told` rather than `notes`: the draft already has a `notes`,
        ' and these two are opposites -- one goes to the model before it
        ' writes, the other to a person after it has.
        told = gdash_nlq.prompt_notes(scaled)
        units_told = true
        on error goto next
        plan = nlq.plan(cat, vocab, q, { dialect: _dialect(), exemplars: ex, notes: told })
        first = error
        if first then
            units_told = false
            plan = nlq.plan(cat, vocab, q, { dialect: _dialect(), exemplars: ex })
            second = error
            if second then
                ' The library's own reason travels with the refusal: "could not
                ' be planned" alone hid a raise that had nothing to do with
                ' the question (found when an installed nlq changed under gdash).
                return _stop("ground", q, "the question could not be planned against this data: " + second.message, { as_of: stamps })
            end if
        end if
        if not plan.ok then
            ' TWO REFUSALS, AND THEY NEED DIFFERENT WORDS. `plan` refuses on
            ' AMBIGUITY (R1/R6 -- more than one object could answer) and, since
            ' 2026-09-14, on NOTHING GROUNDED, which gdash asked for. Both
            ' arrive as `ok: false` with `refused_because`, so the kind has to
            ' be read.
            '
            ' Telling someone "that could mean more than one thing" when the
            ' dashboard has no such data at all sends them looking for a
            ' disambiguation that does not exist. gdash reported this shape to
            ' the platform and then made exactly that mistake against the fixed
            ' library the first time it ran.
            return _stop("ground", q, _refusal_words(plan), { candidates: plan.refused_because, as_of: stamps, units_told: units_told })
        end if

        ' AND A PLAN CAN BE `ok` WITH NOTHING TO ANSWER FROM. `nlq.plan`
        ' refuses on AMBIGUITY; it does not refuse a question the catalog has
        ' nothing to do with, and returns a prompt naming no tables at all.
        ' Found by tests/nlq_corpus.bas: five questions about data this
        ' dashboard has never heard of -- share price, support tickets, the
        ' chief executive -- all planned `ok`. Every one would have been sent
        ' to a model, paid for, and then refused by check_sql for naming a
        ' table nobody offered.
        '
        ' `nlq.check_answerable` is the library's own rule for this and raises
        ' rather than returning, so it is caught here and turned into the same
        ' kind of value as every other stop. The words that matched nothing are
        ' what a person needs, so they are what the message says.
        on error goto next
        answerable = nlq.check_answerable(plan.grounding)
        if error then
            words = ""
            if has(plan.grounding, "unresolved") and count(plan.grounding.unresolved) > 0 then
                words = ": nothing here matches " + join(plan.grounding.unresolved, ", ")
            end if
            return _stop("ground", q, "this dashboard has no data that could answer that" + words, { as_of: stamps })
        end if

        ' THE BUDGET, checked before the model is called and charged after
        ' (GDASH-16). A refusal here has cost nothing.
        lim = gdash_limits.for_root(p)
        gate = gdash_spend.check_budget(p, lim, wire.ctx)
        if not gate.ok then
            return _stop("budget", q, gate.message, { key: plan.key, as_of: stamps })
        end if
        got = wire.complete(wire.ctx, plan.system, plan.user)
        ' Charged whether or not the answer was usable: a model that replied
        ' with prose was still paid. A transport failure reports no usage and
        ' the call never reached a model, so it is not charged.
        if got.ok or not is_unknown(got["usage"]) then
            charged = gdash_spend.charge(p, wire.ctx, got["usage"], len(plan.system) + len(plan.user))
        end if
        if not got.ok then
            return _stop("model", q, got.reason, { key: plan.key, as_of: stamps, units_told: units_told })
        end if

        reading = nlq.interpret(plan, got.text, {})
        if error then
            return _stop("sql", q, "the model did not return a query", { key: plan.key, as_of: stamps })
        end if
        ' The literal-restating guard that stood here is GONE (GDASH-20): it
        ' existed because `amount > 1000` silently meant ten dollars against
        ' minor units, and against money it means USD 1000, which is what the
        ' question said. `notes` stays in the draft's shape, empty.
        notes = []
        if not reading.ok then
            ' check_sql found something: not read-only, or naming an object the
            ' grounding does not have. The SQL goes back with it, because the
            ' person reviewing is the one who can tell whether the question or
            ' the data was wrong.
            return _stop("sql", q, "the generated query was refused",
                         { sql: reading.sql, problems: reading.problems, notes: notes,
                           tables: reading.tables, key: reading.key, as_of: stamps,
                           units_told: units_told })
        end if

        ran = gdash_store.select_across(db, reading.sql)
        if not ran.ok then
            return _stop("run", q, ran.message,
                         { sql: reading.sql, notes: notes, tables: reading.tables,
                           key: reading.key, as_of: stamps, units_told: units_told })
        end if

        settled = nlq.settle(reading, ran.rows)
        if error then
            return _stop("run", q, "the answer could not be settled",
                         { sql: reading.sql, notes: notes, tables: reading.tables,
                           key: reading.key, as_of: stamps })
        end if

        ' The scaled columns travel with the draft, because promotion needs
        ' them and recomputing would mean opening the datasets a second time to
        ' learn something this call already knows.
        return { ok: true, stage: "answered", question: q, message: "",
                 candidates: [], sql: reading.sql, problems: [], notes: notes,
                 rows: ran.rows, answer: settled, tables: reading.tables,
                 key: reading.key, as_of: stamps, scaled: scaled,
                 units_told: units_told }
    end function


    ' --- promoting a draft into the dashboard ------------------------------
    '
    ' THE TWO TIERS NAME TABLES THE SAME WAY NOW. Before GDASH-20 the NLQ
    ' catalog attached every dataset under its own name, so a generated query
    ' said `orders.orders` where a visual query said `orders`. Every dataset is
    ' now a bare table in one database, and the catalog names it bare.
    '
    ' Requalifying stays, because it costs nothing on a bare query and it is
    ' what makes a draft written in the old `D.D` form promotable: the sequence
    ' `D . D` becomes `D` for every dataset name D, so `orders.orders` becomes
    ' `orders` and `orders.orders.amount` becomes `orders.amount`. A qualified
    ' column like `orders.amount` is left exactly as it is.
    '
    ' A dataset name inside a string literal is not rewritten.

    ' A character scan rather than a token rebuild: the tokenizer drops
    ' whitespace, so reassembling from tokens would return SQL that is valid
    ' and unreadable, and this text goes into a record a person maintains. So
    ' the original is preserved everywhere except the spans that are replaced.
    '
    ' Quoted spans are skipped, so a dataset name inside a string literal is
    ' left alone. Identifier boundaries are checked on both sides, so
    ' `myorders.orders` is not rewritten. The comparison is case-insensitive
    ' because SQL identifiers are, and a model will sometimes shout.
    function requalify(sql, datasets)
        out = ""
        i = 0
        n = len(sql)
        while i < n
            ch = mid(sql, i, 1)
            if ch = "'" or ch = chr(34) then
                j = i + 1
                while j < n and mid(sql, j, 1) != ch
                    j += 1
                end while
                if j < n then
                    j += 1
                end if
                out = out + mid(sql, i, j - i)
                i = j
            else
                hit = _dataset_prefix_at(sql, i, datasets)
                if hit > 0 then
                    out = out + mid(sql, i, hit)
                    i += hit * 2 + 1
                else
                    out = out + ch
                    i += 1
                end if
            end if
        end while
        return out
    end function

    ' The length of the dataset name if `sql` at `at` begins a `D.D` sequence
    ' on identifier boundaries, and 0 otherwise. Returning the length rather
    ' than the name keeps the caller a single scan.
    ' Its own boundary predicate, deliberately NOT gdash_nlq._is_ident_char:
    ' that one counts `.` as part of an identifier, so that `a.b.c` is one
    ' token for the unit guard. Here the dot is the thing being matched, so
    ' reusing it made `orders.orders.amount` invisible -- the trailing `.amount`
    ' read as "still inside a name". Caught by probe before it reached a test.
    function _is_name_char(ch)
        return (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch = "_"
    end function

    function _dataset_prefix_at(sql, at, datasets)
        if at > 0 and _is_name_char(mid(sql, at - 1, 1)) then
            return 0
        end if
        k = 0
        while k < count(datasets)
            d = datasets[k]
            w = len(d)
            span = w * 2 + 1
            if at + span <= len(sql) then
                if lower(mid(sql, at, w)) = lower(d) then
                    if mid(sql, at + w, 1) = "." then
                        if lower(mid(sql, at + w + 1, w)) = lower(d) then
                            after = at + span
                            if after >= len(sql) or not _is_name_char(mid(sql, after, 1)) then
                                return w
                            end if
                        end if
                    end if
                end if
            end if
            k += 1
        end while
        return 0
    end function

    ' Which dataset a promoted visual names. Any of them would run -- every
    ' sibling is a table in the same database -- so this takes THE FIRST ONE
    ' THE QUERY NAMES, which is the one "No data yet" should be about.
    '
    ' Not the first one the GROUNDING names, which was the first attempt and
    ' was wrong: "total by region" grounds both `orders` and `regions`, because
    ' both have a region column, while the SQL the model wrote touches only
    ' `orders`. A visual whose `dataset` is a table its query never mentions
    ' loads and renders, so nothing would have caught it later.
    '
    ' A column that happens to be named like a dataset would mislead this. The
    ' cost is a visual opening the wrong sibling, which still renders, and a
    ' person editing one word.
    function primary_of(draft, datasets)
        sql = string(draft.sql)
        i = 0
        n = len(sql)
        while i < n
            ch = mid(sql, i, 1)
            if ch = "'" or ch = chr(34) then
                j = i + 1
                while j < n and mid(sql, j, 1) != ch
                    j += 1
                end while
                i = j + 1
            else if _is_name_char(ch) and (i = 0 or not _is_name_char(mid(sql, i - 1, 1))) then
                j = i
                while j < n and _is_name_char(mid(sql, j, 1))
                    j += 1
                end while
                word = lower(mid(sql, i, j - i))
                k = 0
                while k < count(datasets)
                    if lower(datasets[k]) = word then
                        return datasets[k]
                    end if
                    k += 1
                end while
                i = j
            else
                i += 1
            end if
        end while
        if count(datasets) > 0 then
            return datasets[0]
        end if
        return ""
    end function

    ' A mark that suits the shape that came back. THREE CASES AND A DEFAULT,
    ' because a suggestion that is wrong is cheap here -- the draft is looked
    ' at by a person before it is anything -- and a suggestion that is absent
    ' means they start from nothing.
    '
    '   one row, one column          -> value
    '   two columns, text then number -> bar
    '   anything else                -> table
    function suggest_encoding(rows)
        if count(rows) = 0 then
            return { mark: "table" }
        end if
        cols = keys(rows[0])
        if count(cols) = 1 then
            if count(rows) = 1 then
                return { mark: "value", value: cols[0] }
            end if
            return { mark: "table" }
        end if
        if count(cols) = 2 then
            if type(rows[0][cols[0]]) = "string" and contains(["number", "money"], type(rows[0][cols[1]])) then
                return { mark: "bar", x: cols[0], y: cols[1] }
            end if
        end if
        return { mark: "table" }
    end function

    ' --- money, one more time ----------------------------------------------
    '
    ' A promoted `sum(amount) as total` should draw as currency. The draft's
    ' own rows answer whether a column IS money -- G-SQL returns an aggregate
    ' of money as money (GDASH-20) -- and when there are no rows to look at,
    ' the query is read, NARROWLY ON PURPOSE:
    '
    '   sum(amount) as total     -> money   (an aggregate over a money column)
    '   amount as total          -> money   (the column itself)
    '   count(*) as n            -> not     (even in a query full of money)
    '   amount / 100 as dollars  -> not     (already converted; not our business)
    '
    ' Anything it cannot read this way is NOT marked, because marking a count
    ' as currency would render 3 as $3.00 -- a wrong answer produced by the
    ' machinery meant to prevent wrong answers. A miss costs one field a person
    ' adds while reviewing the draft, which they are doing anyway.
    function _aggregates()
        return ["sum", "avg", "min", "max", "total"]
    end function

    ' Does `alias` name an output column that carries money?
    function is_money_channel(sql, scaled, alias)
        toks = gdash_nlq.tokens(sql)
        i = 0
        while i < count(toks)
            if toks[i].kind = "word" and lower(toks[i].text) = "as" and i + 1 < count(toks) then
                if lower(toks[i + 1].text) = lower(alias) then
                    return _expr_is_money(toks, i - 1, scaled)
                end if
            end if
            i += 1
        end while
        ' No alias: the column may be named directly in the select list.
        return _names_money(alias, scaled)
    end function

    ' The expression ending at `at`, read backwards. Either a bare money column
    ' or an aggregate wrapping exactly one.
    function _expr_is_money(toks, at, scaled)
        if at < 0 then
            return false
        end if
        if toks[at].kind = "word" then
            return _names_money(toks[at].text, scaled)
        end if
        if toks[at].kind = "punct" and toks[at].text = ")" then
            depth = 0
            j = at
            while j >= 0
                if toks[j].kind = "punct" and toks[j].text = ")" then
                    depth += 1
                end if
                if toks[j].kind = "punct" and toks[j].text = "(" then
                    depth -= 1
                    if depth = 0 then
                        ' The function name sits just before the open paren,
                        ' and the single argument just after it.
                        if j - 1 >= 0 and j + 1 < count(toks) then
                            if toks[j - 1].kind = "word" and contains(_aggregates(), lower(toks[j - 1].text)) then
                                if j + 2 = at then
                                    return _names_money(toks[j + 1].text, scaled)
                                end if
                            end if
                        end if
                        return false
                    end if
                end if
                j -= 1
            end while
        end if
        return false
    end function

    ' A query may spell a money column bare, as `<table>.<column>`, or in the
    ' `<table>.<table>.<column>` form a pre-GDASH-20 draft carried.
    function _names_money(word, scaled)
        w = lower(trim(string(word)))
        if w = "" then
            return false
        end if
        for each k in keys(scaled)
            sc = scaled[k]
            bare = lower(sc.column)
            qual = lower(sc.dataset + "." + sc.column)
            full = lower(sc.dataset + "." + sc.dataset + "." + sc.column)
            if w = bare or w = qual or w = full then
                return true
            end if
        next
        return false
    end function

    ' The visual a draft would become. Returned rather than written, because
    ' the whole shape of this feature is that a person looks at it first.
    function draft_visual(draft, rec, scaled)
        datasets = sort(keys(rec["datasets"]))
        rewritten = requalify(draft.sql, datasets)
        enc = suggest_encoding(draft.rows)

        ' The channel that carries a quantity, if this mark has one.
        channel = ""
        if default(enc["mark"], "") = "value" then
            channel = string(enc["value"])
        else if default(enc["mark"], "") = "bar" then
            channel = string(enc["y"])
        end if
        if channel != "" then
            if _carries_money(draft.rows, rewritten, scaled, channel) then
                ' AND ONLY IF THE RENDERER COULD FIND A SCALE FOR IT. Setting
                ' `format: "currency"` on a channel whose scale cannot be
                ' resolved produced a visual that validated, promoted, and then
                ' rendered an error instead of a chart (G13-4). Since G20-9 an
                ' unresolved scale renders at the currency's own places, so a
                ' money channel is always formatted.
                '
                ' THE CURRENCY IS THE VALUE'S, read from the draft's rows: on a
                ' multi-currency dashboard the first currency in reach could be
                ' the wrong one, and a stated currency that disagrees with the
                ' value is refused at render.
                enc["format"] = "currency"
                cur = _value_currency(draft.rows, channel)
                if cur = "" then
                    cur = _currency_of(scaled)
                end if
                if cur != "" then
                    enc["currency"] = cur
                end if
            end if
        end if

        ' The REQUALIFIED query is what primary_of reads, because that is the
        ' text the visual will run.
        return { dataset: primary_of({ sql: rewritten }, datasets),
                 sql: rewritten,
                 encoding: enc }
    end function

    ' The currency of the value a draft's channel actually holds, or "".
    function _value_currency(rows, channel)
        if type(rows) = "array" and count(rows) > 0 then
            v = rows[0][channel]
            if type(v) = "money" then
                return money.currency(v)
            end if
        end if
        return ""
    end function

    ' The rows first, because they know: a value that came back as money is
    ' money. The query is read only when there is no row to ask.
    function _carries_money(rows, sql, scaled, channel)
        if type(rows) = "array" and count(rows) > 0 then
            v = rows[0][channel]
            if not is_unknown(v) then
                return type(v) = "money"
            end if
        end if
        return is_money_channel(sql, scaled, channel)
    end function

    ' The dialect the model is told it writes. gBASIC's own SQL: values keep
    ' their kinds, text joins with ||, and there is no RIGHT or FULL JOIN.
    function _dialect()
        return "G-SQL (PostgreSQL-like; text joins with ||; no RIGHT JOIN or FULL JOIN)"
    end function

    function _currency_of(scaled)
        for each k in keys(scaled)
            if scaled[k].currency != "" then
                return scaled[k].currency
            end if
        next
        return ""
    end function

    ' Writing it into the record. The record file is the authoring surface
    ' (design §10), so this edits that file and nothing else -- it does not
    ' publish, and a published dashboard is unaffected until somebody does.
    '
    ' VALIDATED BEFORE IT IS WRITTEN, not after. A record gdash would refuse to
    ' load is a dashboard that stops rendering for everyone, and the draft that
    ' caused it would be gone by then.
    function promote(p, name, id, visual)
        vid = trim(string(id))
        if vid = "" then
            return { ok: false, message: "a promoted visual needs a name" }
        end if
        path = gdash_paths.record_file(p, name)
        got = gdash_record.load_file(path)
        if not got.ok then
            return { ok: false, message: "the record cannot be read: " + join(got.errors, "; ") }
        end if
        rec = got.record
        if not is_unknown(rec["visuals"][vid]) then
            return { ok: false, message: "this dashboard already has a visual named '" + vid + "'" }
        end if
        rec["visuals"][vid] = visual
        rec["tabs"] = _place(rec["tabs"], vid)

        errs = gdash_record.validate(rec)
        if count(errs) > 0 then
            return { ok: false, message: "the promoted visual would not validate: " + join(errs, "; ") }
        end if

        on error goto next
        tmp = path + ".tmp"
        f {file} = tmp
        write(f, encode(rec))
        if error then
            return { ok: false, message: "cannot write " + tmp }
        end if
        atomic_replace(tmp, path)
        if error then
            return { ok: false, message: "cannot replace " + path }
        end if
        return { ok: true, message: "promoted as '" + vid + "'" }
    end function

    ' Into the first tab, so it is actually on the page. A visual in `visuals`
    ' that no tab names renders nowhere, which would be a promotion that
    ' appeared to work.
    function _place(tabs, vid)
        if is_unknown(tabs) or type(tabs) != "array" or count(tabs) = 0 then
            return [{ name: "Drafts", layout: { vert: [{ visual: vid }] } }]
        end if
        first = tabs[0]
        lay = first["layout"]
        if type(lay) = "record" and type(lay["vert"]) = "array" then
            lay["vert"] = concat(lay["vert"], [{ visual: vid }])
        else
            lay = { vert: [lay, { visual: vid }] }
        end if
        first["layout"] = lay
        tabs[0] = first
        return tabs
    end function

end library
