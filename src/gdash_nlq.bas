' gdash — what a question needs to know about a dashboard's data.
'
' The gBASIC `nlq` library performs no I/O: it grounds a question against a
' catalog, builds a prompt, checks what a model wrote, and settles an answer.
' Everything between those steps is the application's. This module is gdash's
' half of that, and it is deliberately the half that needs no model: a
' catalog, some sampled values, and a check on the SQL that comes back.
'
' gdash is an unusual consumer. It does not need `discovery.scan`, because it
' WROTE these tables: every column's kind and scale was recorded in
' `_gdash_meta` at materialization (design §4), and the dataset names come from
' the record. What a general estate has to recover, gdash simply knows.
'
' It also has a hazard no general estate has, and `unit_notes` below is the
' whole reason this module is worth writing.

library gdash_nlq

    load gdash_paths from "gdash_paths.bas"
    load gdash_store from "gdash_store.bas"
    load gdash_format from "gdash_format.bas"

    ' Every dataset of this dashboard that has actually been refreshed, as the
    ' { name: file } map the store's cross-dataset reads take. A dataset that
    ' has never refreshed has no file and is not in the catalog: a question
    ' cannot be answered from a table that does not exist, and offering its
    ' name would be offering a table whose columns are a guess.
    function attach_for(p, name, mode, rec)
        out = {}
        names = keys(rec["datasets"])
        i = 0
        while i < count(names)
            path = gdash_paths.dataset_db(p, name, mode, names[i])
            if gdash_paths.path_exists(path) then
                out[names[i]] = path
            end if
            i += 1
        end while
        return out
    end function

    ' The catalog `nlq` takes: two arrays, tables and columns. Every dataset is
    ' attached under its own name, so a table is `<dataset>.<dataset>` for all
    ' of them rather than `main.<primary>` for one and its own name for the
    ' rest -- see gdash_store._connect_across for why that matters here and not
    ' in a visual query.
    function catalog(desc)
        tables = []
        columns = []
        names = sort(keys(desc.datasets))
        i = 0
        while i < count(names)
            ds = names[i]
            tables = concat(tables, [{ schema: ds, table: ds }])
            cols = desc.datasets[ds].columns
            j = 0
            while j < count(cols)
                columns = concat(columns, [{ schema: ds, table: ds, column: cols[j].name }])
                j += 1
            end while
            i += 1
        end while
        return { tables: tables, columns: columns }
    end function

    ' Every column gdash stores at a scale, keyed the way a grounding names
    ' them. Currency is the record's to say -- `_gdash_meta` carries kind and
    ' scale, because a file has to be readable without the record that made it,
    ' and a currency code is presentation.
    function scaled_columns(desc, rec)
        out = {}
        names = keys(desc.datasets)
        i = 0
        while i < count(names)
            ds = names[i]
            cols = desc.datasets[ds].columns
            declared = {}
            if not is_unknown(rec["datasets"][ds]) then
                if not is_unknown(rec["datasets"][ds]["columns"]) then
                    declared = rec["datasets"][ds]["columns"]
                end if
            end if
            j = 0
            while j < count(cols)
                c = cols[j]
                if c.kind = "money" then
                    cur = ""
                    if not is_unknown(declared[c.name]) then
                        cur = string(default(declared[c.name]["currency"], ""))
                    end if
                    out[ds + "." + ds + "." + c.name] = { dataset: ds, column: c.name, scale: c.scale, currency: cur }
                end if
                j += 1
            end while
            i += 1
        end while
        return out
    end function

    ' --- telling the model what the integers mean --------------------------
    '
    ' THE CHANNEL GDASH ASKED FOR, AND GOT. Step 0 measured the failure this
    ' closes: "how many orders were over 1000 dollars?" against a column
    ' holding cents produced valid SQL, zero reported problems, and an answer
    ' wrong by a factor of a hundred. Nothing in the prompt said the integers
    ' were minor units -- `vocabulary` shows values and `exemplars` show
    ' formats, and neither can say SCALE.
    '
    ' `nlq.plan` now takes `notes`, a map from object id to a sentence, and
    ' renders only the notes for objects the grounding actually selected (the
    ' budget is what that protects). gdash needs no `discovery` for this: it
    ' wrote these tables and recorded every kind and scale at materialization,
    ' so the note is generated rather than annotated by hand.
    '
    ' THE LAST CLAUSE IS THE ONE THAT MATTERS. Stating the factor is not
    ' enough -- a model that knows amounts are in cents can still write
    ' `amount > 1000` for "over 1000 dollars" if nothing connects the two. So
    ' the note spells out what the literal 1000 would mean in that column,
    ' which is the exact mistake that was measured.
    function prompt_notes(scaled)
        out = {}
        for each key in keys(scaled)
            sc = scaled[key]
            out[key] = _note_text(sc)
        next
        return out
    end function

    function _note_text(sc)
        unit = "whole units"
        named = ""
        if sc.currency != "" then
            unit = sc.currency
            named = " of " + sc.currency
        end if
        if sc.scale = 0 then
            ' No minor unit at all. Saying "stored as minor units" here would
            ' invite a division that must not happen -- JPY is whole yen.
            return "stored as a whole number" + named + ", with no minor unit: the literal 1000 means 1000 " + unit + "."
        end if
        one = "1"
        i = 0
        while i < sc.scale
            one = one + "0"
            i += 1
        end while
        ' "1 units is stored as 10000" is what the obvious phrasing produced for
        ' a column with no declared currency. A note meant to stop a model
        ' misreading a number should not itself read badly.
        whole = "a value of 1"
        if sc.currency != "" then
            whole = "1 " + sc.currency
        end if
        return ("stored as INTEGER MINOR UNITS" + named + " at scale " + string(sc.scale) +
                ": " + whole + " is stored as " + one +
                ", and the literal 1000 means " + gdash_format.minor_to_decimal("1000", sc.scale) + " " + unit +
                ". Write comparisons and sums in minor units, never in whole " + unit + ".")
    end function

    ' --- the unit guard ------------------------------------------------------
    '
    ' THE FAILURE THIS EXISTS FOR, measured at GDASH-12 step 0 against real
    ' staged data and the shipped library:
    '
    '     question:  how many orders were over 1000 dollars?
    '     generated: select count(*) from orders.orders where amount > 1000
    '     plan ok, interpret ok, zero problems
    '     returned 6; the answer is 2
    '
    ' gdash stages money as INTEGER minor units, so `amount` holds 125075 for
    ' $1250.75. Nothing in the prompt says so -- `nlq.vocabulary` shows values
    ' and `nlq.exemplars` shows formats, and neither can say SCALE -- so the
    ' model compares cents to a number of dollars. The SQL is valid, the table
    ' is right, the question is answerable, and the number is wrong by a
    ' hundred. Reported as gdash12_platform_report_nlq.md finding 1.
    '
    ' THIS DOES NOT DECIDE, IT RESTATES. `amount > 1000` is not necessarily
    ' wrong -- someone may genuinely mean ten dollars -- and gdash cannot read
    ' intent. What it can do is say what the number means in the column's own
    ' units, so a person reviewing the draft sees the mistake in one glance
    ' instead of checking arithmetic they have no reason to suspect.
    '
    ' Lexical, and it says so, exactly as `nlq.check_sql` is lexical. It reads
    ' identifiers, numbers and comparison operators; it is not a SQL parser,
    ' and a comparison hidden in a construct it does not model will pass it.
    ' The cost of a miss is the status quo, so the shallow version is worth
    ' having and the deep one is not worth waiting for.
    function _is_ident_char(ch)
        return (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch = "_" or ch = "."
    end function

    function _is_digit(ch)
        return ch >= "0" and ch <= "9"
    end function

    ' Identifiers, numbers, strings and everything else, in order. Strings are
    ' kept as one token so an operator inside a literal cannot be read as an
    ' operator.
    function tokens(sql)
        out = []
        i = 0
        n = len(sql)
        while i < n
            ch = mid(sql, i, 1)
            if ch = " " or ch = chr(9) or ch = chr(10) or ch = chr(13) then
                i += 1
            else if ch = "'" or ch = chr(34) then
                quote = ch
                j = i + 1
                while j < n and mid(sql, j, 1) != quote
                    j += 1
                end while
                out = concat(out, [{ kind: "string", text: mid(sql, i, j - i + 1) }])
                i = j + 1
            else if _is_digit(ch) then
                j = i
                while j < n and (_is_digit(mid(sql, j, 1)) or mid(sql, j, 1) = ".")
                    j += 1
                end while
                out = concat(out, [{ kind: "number", text: mid(sql, i, j - i) }])
                i = j
            else if _is_ident_char(ch) then
                j = i
                while j < n and _is_ident_char(mid(sql, j, 1))
                    j += 1
                end while
                out = concat(out, [{ kind: "word", text: mid(sql, i, j - i) }])
                i = j
            else if (ch = "<" or ch = ">" or ch = "!") and i + 1 < n and mid(sql, i + 1, 1) = "=" then
                out = concat(out, [{ kind: "op", text: mid(sql, i, 2) }])
                i += 2
            else if ch = "<" and i + 1 < n and mid(sql, i + 1, 1) = ">" then
                out = concat(out, [{ kind: "op", text: "<>" }])
                i += 2
            else if ch = "<" or ch = ">" or ch = "=" then
                out = concat(out, [{ kind: "op", text: ch }])
                i += 1
            else
                out = concat(out, [{ kind: "punct", text: ch }])
                i += 1
            end if
        end while
        return out
    end function

    ' Which scaled column, if any, a word names. A generated query may write
    ' `amount`, `orders.amount` or `orders.orders.amount`; all three mean the
    ' same column, and a guard that only recognised the longest form would miss
    ' the spelling a model is most likely to use.
    function _scaled_match(word, scaled)
        ks = keys(scaled)
        lw = lower(word)
        i = 0
        while i < count(ks)
            sc = scaled[ks[i]]
            bare = lower(sc.column)
            qual = lower(sc.dataset + "." + sc.column)
            full = lower(sc.dataset + "." + sc.dataset + "." + sc.column)
            if lw = bare or lw = qual or lw = full then
                return sc
            end if
            i += 1
        end while
        return unknown
    end function

    ' Looking left from an operator for the column it compares. `amount > 1000`
    ' puts the identifier immediately left; `sum(amount) > 1000` puts a bracket
    ' there, so a closing bracket is walked back through. That covers the two
    ' shapes a generated aggregate actually takes.
    function _column_left_of(toks, at, scaled)
        i = at - 1
        depth = 0
        while i >= 0
            t = toks[i]
            if t.kind = "punct" and t.text = ")" then
                depth += 1
            else if t.kind = "punct" and t.text = "(" then
                if depth = 0 then
                    return unknown
                end if
                depth -= 1
            else if t.kind = "word" then
                m = _scaled_match(t.text, scaled)
                if not is_unknown(m) then
                    return m
                end if
                if depth = 0 then
                    return unknown
                end if
            else if t.kind = "number" or t.kind = "string" then
                if depth = 0 then
                    return unknown
                end if
            end if
            i -= 1
        end while
        return unknown
    end function

    function _note(sc, literal)
        ' The literal as the column itself would render it -- which is the
        ' whole point: 1000 against a scale of 2 is ten dollars, and seeing
        ' "$10.00" beside a question about a thousand ends the matter.
        '
        ' The plain decimal first, because it always works: `currency` answers
        ' with a record carrying its own `ok`, and an unsupported code or an
        ' out-of-range value must leave a readable number behind rather than a
        ' blank where the point of the note was.
        on error goto next
        shown = gdash_format.minor_to_decimal(literal, sc.scale)
        if error then
            shown = literal
        end if
        if sc.currency != "" then
            cur = gdash_format.currency(literal, sc.scale, sc.currency)
            if not error and cur.ok then
                shown = cur.text
            end if
        end if
        return { column: sc.dataset + "." + sc.column, literal: literal, means: shown, scale: sc.scale,
                 why: "stored in minor units at scale " + string(sc.scale) + ", so " + literal + " means " + shown }
    end function

    ' Every comparison between a scaled column and a bare number, restated.
    function unit_notes(sql, scaled)
        out = []
        if count(keys(scaled)) = 0 then
            return out
        end if
        toks = tokens(sql)
        i = 0
        while i < count(toks)
            t = toks[i]
            if t.kind = "op" then
                sc = _column_left_of(toks, i, scaled)
                if not is_unknown(sc) and i + 1 < count(toks) then
                    if toks[i + 1].kind = "number" then
                        out = concat(out, [_note(sc, toks[i + 1].text)])
                    end if
                end if
                ' `1000 < amount` is the same comparison written backwards.
                if is_unknown(sc) and i > 0 and i + 1 < count(toks) then
                    if toks[i - 1].kind = "number" and toks[i + 1].kind = "word" then
                        right = _scaled_match(toks[i + 1].text, scaled)
                        if not is_unknown(right) then
                            out = concat(out, [_note(right, toks[i - 1].text)])
                        end if
                    end if
                end if
            else if t.kind = "word" and lower(t.text) = "between" then
                ' `amount between 1000 and 2000` -- two literals, one column,
                ' and the operator-based branch above never fires on it.
                sc = _column_left_of(toks, i, scaled)
                if not is_unknown(sc) then
                    j = i + 1
                    taken = 0
                    while j < count(toks) and taken < 2
                        if toks[j].kind = "number" then
                            out = concat(out, [_note(sc, toks[j].text)])
                            taken += 1
                        else if toks[j].kind = "word" and lower(toks[j].text) != "and" then
                            j = count(toks)
                        end if
                        j += 1
                    end while
                end if
            end if
            i += 1
        end while
        return out
    end function

end library
