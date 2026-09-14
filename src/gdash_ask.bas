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
    load gdash_format from "gdash_format.bas"
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
        answer = llm.ask(m, system, user)
        if error then
            ' llm RAISES on transport and provider failure, including auth
            ' rejection and 429/5xx after its retry budget. A raise inside a
            ' request handler kills the worker (PLAT-WEB, let-it-crash), so it
            ' stops here and becomes a value like every other outcome.
            return { ok: false, text: "", reason: "the model could not be reached" }
        end if
        if is_unknown(answer) then
            ' An empty completion is llm's `unknown`, and it is not an error:
            ' the model was reached and said nothing useful.
            return { ok: false, text: "", reason: "the model returned nothing" }
        end if
        return { ok: true, text: string(answer), reason: "" }
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
        if provider = "local" then
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
    ' a number's spellings teach nothing, and a money column's would teach the
    ' wrong lesson twice over -- the integers are minor units, which is the
    ' failure the unit guard exists for.
    '
    ' `nlq.vocabulary` drops any column with more values than its cap, which is
    ' the right behaviour and means gdash can sample generously: a partial list
    ' would be worse than none, because a literal absent from it reads as
    ' unknown rather than merely unlisted.
    function value_rows(attach, desc, cap)
        rows = []
        dsn = sort(keys(desc.datasets))
        i = 0
        while i < count(dsn)
            ds = dsn[i]
            cols = desc.datasets[ds].columns
            j = 0
            while j < count(cols)
                if cols[j].kind = "text" then
                    vals = gdash_store.sample_column(attach, ds, cols[j].name, cap + 1)
                    if count(vals) > 0 then
                        rows = concat(rows, [{ schema: ds, table: ds, column: cols[j].name, values: vals }])
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
    function as_of(p, name, mode, attach)
        out = []
        dsn = sort(keys(attach))
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
                 answer: unknown, tables: [], key: "", as_of: [] }
        for each k in keys(extra)
            base[k] = extra[k]
        next
        return base
    end function

    function ask(p, name, mode, rec, question, wire, options)
        q = trim(string(question))
        if q = "" then
            return _stop("ground", q, "ask a question", {})
        end if

        attach = gdash_nlq.attach_for(p, name, mode, rec)
        if count(keys(attach)) = 0 then
            return _stop("data", q, "no dataset of this dashboard has been refreshed yet, so there is nothing to ask about", {})
        end if

        desc = gdash_store.describe_datasets(attach)
        if not desc.ok then
            return _stop("data", q, desc.message, {})
        end if

        stamps = as_of(p, name, mode, attach)
        cat = gdash_nlq.catalog(desc)
        scaled = gdash_nlq.scaled_columns(desc, rec)

        rows = value_rows(attach, desc, 25)
        vocab = nlq.vocabulary(rows, { max_values: 25 })
        ex = nlq.exemplars(rows, { min_distinct: 2 })

        on error goto next
        plan = nlq.plan(cat, vocab, q, { dialect: "SQLite", exemplars: ex })
        if error then
            return _stop("ground", q, "the question could not be planned against this data", { as_of: stamps })
        end if
        if not plan.ok then
            ' R1/R6: a grounding the catalog could not settle is a refusal, and
            ' it travels as a value carrying the candidates -- so the UI asks
            ' the person which one they meant instead of guessing.
            return _stop("ground", q, "that could mean more than one thing", { candidates: plan.refused_because, as_of: stamps })
        end if

        got = wire.complete(wire.ctx, plan.system, plan.user)
        if not got.ok then
            return _stop("model", q, got.reason, { key: plan.key, as_of: stamps })
        end if

        reading = nlq.interpret(plan, got.text, {})
        if error then
            return _stop("sql", q, "the model did not return a query", { key: plan.key, as_of: stamps })
        end if
        notes = gdash_nlq.unit_notes(reading.sql, scaled)
        if not reading.ok then
            ' check_sql found something: not read-only, or naming an object the
            ' grounding does not have. The SQL goes back with it, because the
            ' person reviewing is the one who can tell whether the question or
            ' the data was wrong.
            return _stop("sql", q, "the generated query was refused",
                         { sql: reading.sql, problems: reading.problems, notes: notes,
                           tables: reading.tables, key: reading.key, as_of: stamps })
        end if

        ran = gdash_store.select_across(attach, reading.sql)
        if not ran.ok then
            return _stop("run", q, ran.message,
                         { sql: reading.sql, notes: notes, tables: reading.tables,
                           key: reading.key, as_of: stamps })
        end if

        settled = nlq.settle(reading, ran.rows)
        if error then
            return _stop("run", q, "the answer could not be settled",
                         { sql: reading.sql, notes: notes, tables: reading.tables,
                           key: reading.key, as_of: stamps })
        end if

        return { ok: true, stage: "answered", question: q, message: "",
                 candidates: [], sql: reading.sql, problems: [], notes: notes,
                 rows: ran.rows, answer: settled, tables: reading.tables,
                 key: reading.key, as_of: stamps }
    end function

end library
