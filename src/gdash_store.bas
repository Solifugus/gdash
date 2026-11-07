' gdash — the staging store.
'
' ALL staging-store access goes through this module (design §3): create,
' insert, swap, select. The backend swap the design anticipated happened
' here, in GDASH-20: SQLite files became G-SQL tables, and no caller learned
' the word `gsql`.
'
' ONE DATABASE PER (DASHBOARD, STAGE), every dataset a table in it
' (gsql_migration_plan.md D1). A dashboard's SQL can therefore name its own
' datasets and nothing else -- the wall between dashboards is the directory,
' not a check in the code -- and a visual query reaches every sibling with no
' attach and no cap.
'
' VALUES ARE gBASIC VALUES. G-SQL stores money as money, with its currency,
' and integers exactly past 2^53, so nothing here converts a number to text
' to protect it. The one conversion left is the column's own: a source's text
' stored into a typed column is read as that column's kind, and refused if it
' does not read as one (a seventh decimal of USD, an empty string for money).
'
' Stale-but-coherent is a transaction now, not a rename: a refresh writes
' `<dataset>__staging` and `swap` drops the live table and renames the staging
' one in a single commit. A reader inside `begin("read")` keeps the snapshot it
' started with until it finishes (GDASH-20 step 0, measured).

library gdash_store

    load gsql
    load crypto
    load gdash_sql from "gdash_sql.bas"
    load gdash_paths from "gdash_paths.bas"

    ' How long an owner this process starts stays up after its last client.
    ' Workers open a connection per request, so a warm owner is the difference
    ' between 0.14 ms and 20-30 ms a request (GDASH-20 step 0). The suite sets
    ' 0 so that nothing it starts outlives it.
    function linger()
        got = env("GDASH_GSQL_LINGER")
        if is_unknown(got) or trim(string(got)) = "" then
            return 30
        end if
        n = number(got)
        if is_unknown(n) or is_nothing(n) then
            return 30
        end if
        return n
    end function

    ' THE ONE CONNECT. Every process that reaches a dashboard's data -- a
    ' worker, the refresh child, the refresh parent, the CLI -- comes through
    ' here, so where the owner's socket lives is one function's business
    ' (GDASH-20 S0-6, asked of the platform as A1).
    '
    ' Without `create`, a database that does not exist is not created: a read
    ' of data that has never refreshed is "no data", not an empty database.
    function connect(path, create)
        if not create and not gdash_paths.path_exists(path) then
            return unknown
        end if
        on error goto next
        db = gsql.connect(path, { create: create, linger: linger() })
        if error then
            return unknown
        end if
        return db
    end function

    function _close(db)
        on error goto next
        gsql.close(db)
        if error then
        end if
    end function

    function _rollback(db)
        on error goto next
        gsql.rollback(db)
        if error then
        end if
    end function

    function staging_name(table)
        return table + "__staging"
    end function

    ' Names the store uses for itself, refused as dataset names by the record
    ' validator: a dataset called `_gdash_meta` would be its own metadata, and
    ' one called `orders__staging` would be another dataset's refresh.
    function reserved(name)
        return starts_with(lower(name), "_gdash") or ends_with(lower(name), "__staging")
    end function

    function _digits_only(s)
        if s = "" then
            return false
        end if
        i = 0
        while i < len(s)
            if not contains("0123456789", mid(s, i, 1)) then
                return false
            end if
            i += 1
        end while
        return true
    end function

    ' The kind a column is stored as. gdash's own vocabulary (money, integer,
    ' real, text) is what `_gdash_meta` records and what ask reads; this is the
    ' G-SQL kind each one becomes -- gBASIC kinds, not SQL types that resemble
    ' them (plan D5).
    function _sql_type(entry)
        if entry.kind = "money" then
            return "money(" + entry.currency + ")"
        end if
        if entry.kind = "integer" then
            return "integer"
        end if
        if entry.kind = "real" then
            return "number"
        end if
        return "string"
    end function

    ' Undeclared columns map: integer-looking -> integer, numeric -> real,
    ' else text (design §4).
    function infer_kind(samples)
        seen = false
        all_int = true
        all_num = true
        i = 0
        while i < count(samples)
            v = trim(string(samples[i]))
            if not is_unknown(samples[i]) and v != "" then
                seen = true
                probe = v
                if starts_with(probe, "-") or starts_with(probe, "+") then
                    probe = mid(probe, 1, len(probe) - 1)
                end if
                if not _digits_only(probe) then
                    all_int = false
                    bits = split(probe, ".")
                    if count(bits) != 2 then
                        all_num = false
                    else
                        lead = bits[0]
                        if lead = "" then
                            lead = "0"
                        end if
                        if not _digits_only(lead) or not _digits_only(bits[1]) then
                            all_num = false
                        end if
                    end if
                end if
            end if
            i += 1
        end while
        if not seen then
            return "text"
        end if
        if all_int then
            return "integer"
        end if
        if all_num then
            return "real"
        end if
        return "text"
    end function

    ' Build the column plan for a dataset: declared money columns keep their
    ' currency and their DISPLAY scale (plan D4a: stored exactly, rounded only
    ' for a person); everything else is inferred from the fetched rows.
    function plan_columns(column_names, rows, declared)
        plan = []
        c = 0
        while c < count(column_names)
            nm = column_names[c]
            d = unknown
            if not is_unknown(declared) then
                d = declared[nm]
            end if
            if not is_unknown(d) and default(d["type"], "") = "money" then
                plan = append(plan, { name: nm, kind: "money", scale: default(d["scale"], 2), currency: string(default(d["currency"], "USD")) })
            else
                samples = []
                r = 0
                while r < count(rows)
                    samples = append(samples, rows[r][c])
                    r += 1
                end while
                plan = append(plan, { name: nm, kind: infer_kind(samples), scale: 0, currency: "" })
            end if
            c += 1
        end while
        return plan
    end function

    function _quote_ident(nm)
        return chr(34) + replace(nm, chr(34), chr(34) + chr(34)) + chr(34)
    end function

    function _ensure_meta(db)
        gsql.exec(db, "create table if not exists _gdash_meta (dataset string, column_name string, kind string, currency string, scale integer, position integer)")
    end function

    ' A cell as the column takes it. Money, integer and real cells go in as the
    ' source gave them and the column reads them; a text cell goes in as text,
    ' because a string column refuses a number rather than spelling it.
    '
    ' Including money padded past its currency's places: a numeric(19,8) source
    ' sends `1100.00000000`, and since gbasic 8633507 (GDASH-20 ask A6) the
    ' money reader counts significant digits, so the stopgap that stripped the
    ' zeros here is gone. A non-zero digit past the storage scale is refused.
    function _cell(entry, raw)
        if is_unknown(raw) or is_nothing(raw) then
            return unknown
        end if
        if entry.kind = "text" then
            return string(raw)
        end if
        return raw
    end function

    ' Rows per `gsql.insert` call, and so per transaction: big enough that a
    ' commit's sync is shared by a thousand rows, small enough that a refresh
    ' never builds all of its records at once.
    function _rows_per_call()
        return 1000
    end function

    ' Materialize fetched rows into `<table>__staging`. Per-column kind,
    ' currency and display scale go into `_gdash_meta` under the staging name,
    ' and `swap` renames them with the table, in the same commit.
    function materialize(db_path, table, plan, rows)
        db = connect(db_path, true)
        if is_unknown(db) then
            return { ok: false, message: "cannot open the staging database: " + db_path, rejected: 0 }
        end if
        staging = staging_name(table)

        defs = []
        i = 0
        while i < count(plan)
            defs = append(defs, _quote_ident(plan[i].name) + " " + _sql_type(plan[i]))
            i += 1
        end while

        on error goto next
        _ensure_meta(db)
        gsql.exec(db, "drop table if exists " + _quote_ident(staging))
        gsql.exec(db, "delete from _gdash_meta where dataset = $1", [staging])
        gsql.exec(db, "create table " + _quote_ident(staging) + " (" + join(defs, ", ") + ")")
        e = error
        if e then
            _close(db)
            return { ok: false, message: "cannot create the staging table: " + e.message, rejected: 0 }
        end if

        i = 0
        while i < count(plan)
            gsql.exec(db, "insert into _gdash_meta values ($1, $2, $3, $4, $5, $6)", [staging, plan[i].name, plan[i].kind, plan[i].currency, plan[i].scale, i])
            i += 1
        end while
        e = error
        if e then
            _close(db)
            return { ok: false, message: "cannot record the staging table's columns: " + e.message, rejected: 0 }
        end if

        ' MANY ROWS A CALL (gsql.insert, GDASH-20 ask A3). Each call converts
        ' and checks every value exactly as INSERT does, and is all or nothing;
        ' a refused row is named by its index in the call, which is turned back
        ' into the row's index in the dataset.
        names = []
        for each entry in plan
            names = append(names, entry.name)
        next
        width = count(plan)
        n = count(rows)
        r = 0
        while r < n
            take = _rows_per_call()
            if n - r < take then
                take = n - r
            end if
            batch = []
            k = 0
            while k < take
                rec = {}
                c = 0
                while c < width
                    rec[names[c]] = _cell(plan[c], rows[r + k][c])
                    c += 1
                end while
                batch = append(batch, rec)
                k += 1
            end while
            gsql.insert(db, staging, batch)
            e = error
            if e then
                ' A refusal, not a rounding: the whole refresh fails, and the
                ' live table is untouched.
                where = "rows " + string(r) + "-" + string(r + take - 1)
                if has(e.details, "index") then
                    where = "row " + string(r + e.details.index)
                end if
                if has(e.details, "column") then
                    where = where + ", column '" + string(e.details.column) + "'"
                end if
                gsql.exec(db, "drop table if exists " + _quote_ident(staging))
                gsql.exec(db, "delete from _gdash_meta where dataset = $1", [staging])
                if error then
                end if
                _close(db)
                return { ok: false, message: where + ": " + e.message, rejected: 1 }
            end if
            r += take
        end while
        _close(db)
        return { ok: true, message: "", rejected: 0 }
    end function

    ' Does `table` exist in this database? Asked of the table itself rather
    ' than of `_gdash_meta`, because the question is whether a query naming it
    ' will find it.
    function _has_table(db, table)
        on error goto next
        gsql.begin(db, "read")
        x = gsql.query(db, "select 1 as one from " + _quote_ident(table) + " limit 1")
        e = error
        _rollback(db)
        if e then
            return false
        end if
        return true
    end function

    function has_dataset(db_path, table)
        db = connect(db_path, false)
        if is_unknown(db) then
            return false
        end if
        got = _has_table(db, table)
        _close(db)
        return got
    end function

    function has_staging(db_path, table)
        return has_dataset(db_path, staging_name(table))
    end function

    ' The swap: one transaction. The live table is dropped and the staging
    ' table renamed over it, with its metadata, in a single commit; a reader
    ' inside `begin("read")` keeps reading the old table until it finishes,
    ' and the version file bumps AFTER, so a notified reader always finds
    ' complete data (design §3).
    function swap(db_path, table)
        db = connect(db_path, false)
        if is_unknown(db) then
            return { ok: false, message: "the staging database is not there: " + db_path }
        end if
        staging = staging_name(table)
        on error goto next
        gsql.begin(db)
        gsql.exec(db, "drop table if exists " + _quote_ident(table))
        gsql.exec(db, "alter table " + _quote_ident(staging) + " rename to " + _quote_ident(table))
        gsql.exec(db, "delete from _gdash_meta where dataset = $1", [table])
        gsql.exec(db, "update _gdash_meta set dataset = $1 where dataset = $2", [table, staging])
        e = error
        if e then
            _rollback(db)
            _close(db)
            return { ok: false, message: e.message }
        end if
        gsql.commit(db)
        e = error
        _close(db)
        if e then
            return { ok: false, message: e.message }
        end if
        return { ok: true, message: "" }
    end function

    ' A failed or unchanged refresh's staging table, and any a crashed child
    ' left behind. True when there is none afterwards.
    function discard_staging(db_path, table)
        db = connect(db_path, false)
        if is_unknown(db) then
            return true
        end if
        staging = staging_name(table)
        on error goto next
        gsql.exec(db, "drop table if exists " + _quote_ident(staging))
        gsql.exec(db, "delete from _gdash_meta where dataset = $1", [staging])
        e = error
        _close(db)
        if e then
            return false
        end if
        return true
    end function

    function _meta_rows(db)
        on error goto next
        gsql.begin(db, "read")
        rows = gsql.query(db, "select dataset, column_name, kind, currency, scale, position from _gdash_meta order by dataset, position")
        e = error
        _rollback(db)
        if e then
            return []
        end if
        out = []
        for each r in rows
            if not ends_with(string(r.dataset), "__staging") then
                out = append(out, r)
            end if
        next
        return out
    end function

    ' Display scales for every money column of this dashboard, keyed by column
    ' name, because a result column is all a renderer has.
    '
    ' CONFLICT IS RECORDED, NOT OVERWRITTEN. Two datasets can each define
    ' `amount` at different scales; a name that means two things maps to -2,
    ' and the renderer refuses rather than picking one (G13-2). With exact
    ' money that refusal protects the number of places shown, not the amount,
    ' and it is kept until a ruling says otherwise.
    function money_columns(db_path)
        db = connect(db_path, false)
        if is_unknown(db) then
            return {}
        end if
        rows = _meta_rows(db)
        _close(db)
        out = {}
        for each r in rows
            if string(r.kind) = "money" then
                nm = string(r.column_name)
                sc = r.scale
                if is_unknown(out[nm]) then
                    out[nm] = sc
                else if out[nm] != sc then
                    out[nm] = -2
                end if
            end if
        next
        return out
    end function

    function table_columns(db_path, table)
        db = connect(db_path, false)
        if is_unknown(db) then
            return []
        end if
        rows = _meta_rows(db)
        _close(db)
        out = []
        for each r in rows
            if string(r.dataset) = table then
                out = append(out, string(r.column_name))
            end if
        next
        return out
    end function

    ' Every column of every refreshed dataset, with the kind and display scale
    ' it was materialized at. This is gdash's own account of its data -- not a
    ' discovery pass over it -- because gdash wrote these tables and recorded
    ' what it wrote.
    function describe_datasets(db_path)
        db = connect(db_path, false)
        if is_unknown(db) then
            return { ok: false, datasets: {}, message: "cannot open the staged data" }
        end if
        rows = _meta_rows(db)
        _close(db)
        out = {}
        for each r in rows
            ds = string(r.dataset)
            if is_unknown(out[ds]) then
                out[ds] = { columns: [] }
            end if
            entry = out[ds]
            entry.columns = append(entry.columns, { name: string(r.column_name), kind: string(r.kind), scale: r.scale, currency: string(default(r.currency, "")) })
            out[ds] = entry
        next
        return { ok: true, datasets: out, message: "" }
    end function

    ' The datasets of this dashboard that have actually been refreshed.
    function datasets(db_path)
        return sort(keys(describe_datasets(db_path).datasets))
    end function

    ' A handful of values a column actually holds. gdash owns the rows, so
    ' sampling costs one query and needs nobody's permission -- which is the
    ' difference between telling a model a column is text and telling it the
    ' text is spelled `north`.
    function sample_column(db_path, ds, column, limit)
        db = connect(db_path, false)
        if is_unknown(db) then
            return []
        end if
        on error goto next
        gsql.begin(db, "read")
        rows = gsql.query(db, "select distinct " + _quote_ident(column) + " as v from " + _quote_ident(ds) + " where " + _quote_ident(column) + " is not null limit " + string(limit))
        e = error
        _rollback(db)
        _close(db)
        if e then
            return []
        end if
        out = []
        for each r in rows
            out = append(out, string(r.v))
        next
        return out
    end function

    ' A query, read-only at the engine. EVERY READ gdash runs goes through a
    ' `begin("read")`: a visual query, a describe, a sample, or SQL a model
    ' wrote. `nlq.check_sql` refuses anything that is not read-only and is the
    ' gate that should stop a generated `delete`; this is what makes a gap in
    ' that gate harmless rather than destructive -- G-SQL refuses a write in a
    ' read transaction as READ_ONLY (GDASH-20 step 0, measured).
    function _read(db_path, sql, args)
        db = connect(db_path, false)
        if is_unknown(db) then
            return { ok: false, rows: [], message: "dataset not available" }
        end if
        on error goto next
        gsql.begin(db, "read")
        rows = gsql.query(db, sql, args)
        e = error
        _rollback(db)
        _close(db)
        if e then
            return { ok: false, rows: [], message: e.message }
        end if
        return { ok: true, rows: rows, message: "" }
    end function

    ' A generated query. Separate from select_rows because it takes NO
    ' PARAMETERS: this is the NLQ path, where the SQL arrived as text from a
    ' model and was checked by `nlq.check_sql`. A failure is a VALUE: a
    ' generated query that does not compile is an ordinary outcome of asking a
    ' question, and it has to reach a person as text they can read.
    function select_across(db_path, sql)
        got = _read(db_path, sql, [])
        if not got.ok then
            return { ok: false, rows: [], message: "the generated query did not run: " + got.message }
        end if
        return got
    end function

    ' Run a visual query. `:name` bindings become positional parameters, bound
    ' from `values` -- typed values, converted where the request arrived (plan
    ' D3), so a date compares as a date.
    function select_rows(db_path, sql, values)
        scanned = gdash_sql.scan(sql)
        args = gdash_sql.args_for(scanned, values)
        return _read(db_path, scanned.sql, args)
    end function

    ' A dataset's content, as one string, hashed. Used to decide whether a
    ' refresh actually changed anything -- an unchanged refresh must not bump
    ' the version, because every open tab reloads when it does.
    '
    ' sha256() returns RAW BYTES and len() will lie about them (finding G2-5);
    ' crypto.sha256_hex is the form that may be stored, compared and encoded.
    function content_hash(column_names, rows)
        parts = [join(column_names, chr(31))]
        r = 0
        while r < count(rows)
            row = rows[r]
            cells = []
            c = 0
            while c < count(row)
                cells = append(cells, string(row[c]))
                c += 1
            end while
            parts = append(parts, join(cells, chr(31)))
            r += 1
        end while
        return crypto.sha256_hex(join(parts, chr(30)))
    end function

    function read_version(path)
        on error goto next
        f {file} = path
        if error then
            return 0
        end if
        if not exists(f) then
            return 0
        end if
        txt = trim(read(f))
        if error then
            return 0
        end if
        n = number(txt)
        if is_unknown(n) or is_nothing(n) then
            return 0
        end if
        return n
    end function

    function bump_version(path, tmp_path)
        v = read_version(path) + 1
        on error goto next
        tf {file} = tmp_path
        write(tf, string(v))
        if error then
            return 0
        end if
        atomic_replace(tmp_path, path)
        if error then
            return 0
        end if
        return v
    end function

end library
