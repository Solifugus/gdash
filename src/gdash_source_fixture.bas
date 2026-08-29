' gdash — the fixture source.
'
' This is the seam that makes the suite hermetic: it stands in for a real
' source, yielding the same row shape without a network or a database. `pg`
' returns numeric/bigint as STRINGS precisely to avoid float loss (design §4),
' so the fixture yields strings too -- a fixture that handed back numbers
' would lie about the thing it stands in for, and would hide exactly the
' truncation finding F1 is about.

library gdash_source_fixture

    ' profile: { kind: "fixture", path: "<file of { columns: [...], rows: [[...]] }>" }
    function fetch(profile, sql)
        path = profile["path"]
        if is_unknown(path) then
            return { ok: false, columns: [], rows: [], message: "fixture profile has no 'path'" }
        end if
        on error goto next
        f {file} = path
        if error then
            return { ok: false, columns: [], rows: [], message: "fixture unreadable: " + string(path) }
        end if
        if not exists(f) then
            return { ok: false, columns: [], rows: [], message: "fixture not found: " + string(path) }
        end if
        text = read(f)
        if error then
            return { ok: false, columns: [], rows: [], message: "fixture unreadable: " + string(path) }
        end if
        parsed = try_decode(text)
        if not parsed.ok then
            return { ok: false, columns: [], rows: [], message: "fixture is not valid JSON: " + string(parsed.message) }
        end if
        doc = parsed.value

        ' A fixture may carry several named result sets so one file can serve
        ' a dataset and a failure case; `sql` selects nothing here, since the
        ' fixture is not a SQL engine. The seam's contract is the row shape,
        ' not the query language.
        cols = doc["columns"]
        rows = doc["rows"]
        if is_unknown(cols) or is_unknown(rows) then
            return { ok: false, columns: [], rows: [], message: "fixture needs 'columns' and 'rows'" }
        end if
        if doc["fail"] = true then
            ' Lets a test drive the failure path without breaking anything real.
            return { ok: false, columns: [], rows: [], message: "fixture is configured to fail" }
        end if
        return { ok: true, columns: cols, rows: rows, message: "" }
    end function

end library
