' gdash — what a question needs to know about a dashboard's data.
'
' The gBASIC `nlq` library performs no I/O: it grounds a question against a
' catalog, builds a prompt, checks what a model wrote, and settles an answer.
' Everything between those steps is the application's. This module is gdash's
' half of that, and it is deliberately the half that needs no model: a
' catalog, some sampled values, and a check on the SQL that comes back.
'
' gdash is an unusual consumer. It does not need `discovery.scan`, because it
' WROTE these tables: every column's kind, currency and scale was recorded in
' `_gdash_meta` at materialization (design §4), and the dataset names come from
' the record. What a general estate has to recover, gdash simply knows.
'
' Until GDASH-20 it also had a hazard no general estate has: money stored as
' integer minor units, so a model comparing `amount > 1000` meant ten dollars
' without knowing it. G-SQL stores money as money, and that comparison now
' means USD 1000 -- so the minor-unit notes and the literal-restating guard are
' gone, and what the model is told is only which currency a column holds.

library gdash_nlq

    load gdash_paths from "gdash_paths.bas"
    load gdash_store from "gdash_store.bas"
    load gdash_format from "gdash_format.bas"

    ' The catalog `nlq` takes: two arrays, tables and columns. Every dataset is
    ' a table in the dashboard's one database, so each is named bare -- with
    ' no schema, the same name a visual query uses -- and only datasets that
    ' have refreshed are in it: a question cannot be answered from a table that
    ' does not exist.
    function catalog(desc)
        tables = []
        columns = []
        names = sort(keys(desc.datasets))
        i = 0
        while i < count(names)
            ds = names[i]
            tables = concat(tables, [{ schema: "", table: ds }])
            cols = desc.datasets[ds].columns
            j = 0
            while j < count(cols)
                columns = concat(columns, [{ schema: "", table: ds, column: cols[j].name }])
                j += 1
            end while
            i += 1
        end while
        return { tables: tables, columns: columns }
    end function

    ' Every money column, keyed the way a grounding names it (`<table>.<column>`,
    ' since a table has no schema). Its currency is recorded in `_gdash_meta`;
    ' the record's declaration is the fallback for a dataset staged before it
    ' was.
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
                    cur = string(default(c.currency, ""))
                    if cur = "" and not is_unknown(declared[c.name]) then
                        cur = string(default(declared[c.name]["currency"], ""))
                    end if
                    out[ds + "." + c.name] = { dataset: ds, column: c.name, scale: c.scale, currency: cur }
                end if
                j += 1
            end while
            i += 1
        end while
        return out
    end function

    ' --- telling the model which currency a column holds -------------------
    '
    ' `nlq.plan` takes `notes`, a map from object id to a sentence, and renders
    ' only the notes for objects the grounding selected. Money is stored as
    ' money (GDASH-20), and G-SQL reads a plain number compared with a money
    ' column as that column's currency -- so the note says which currency, and
    ' that a plain number means an amount of it. It no longer has a unit to
    ' warn about.
    function prompt_notes(scaled)
        out = {}
        for each key in keys(scaled)
            sc = scaled[key]
            out[key] = _note_text(sc)
        next
        return out
    end function

    function _note_text(sc)
        if sc.currency = "" then
            return "money; compare it with a plain number of the same currency."
        end if
        return "money in " + sc.currency + ", stored exactly: compare it with a plain number of " + sc.currency + " -- the literal 1000 means " + sc.currency + " 1000."
    end function

    ' --- the tokenizer ---------------------------------------------------------
    '
    ' Lexical, and it says so, exactly as `nlq.check_sql` is lexical: promotion
    ' reads a draft's select list with it. It is not a SQL parser.
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

end library
