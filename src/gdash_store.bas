' gdash — the staging store.
'
' ALL staging-store access goes through this module (design §3): create,
' insert, swap, select. A future backend swap is this module's rewrite, which
' is discipline rather than a pluggable abstraction layer.
'
' The money boundary lives here and nowhere else. gBASIC numbers are IEEE-754
' doubles, so an integer above 2^53 is silently truncated crossing the SQLite
' binding in either direction (finding F1). Minor units therefore travel as
' decimal TEXT: a numeric string bound into an INTEGER column stores an exact
' int64, and `cast(col as text)` brings it back exactly. Never divide minor
' units in gBASIC -- that division is itself a 2^53 hop.

library gdash_store

    load sqlite
    load crypto
    load gdash_sql from "gdash_sql.bas"

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

    function _strip_leading_zeros(s)
        i = 0
        while i < len(s) - 1 and mid(s, i, 1) = "0"
            i += 1
        end while
        return mid(s, i, len(s) - i)
    end function

    ' Decimal text -> integer minor units, as TEXT. Excess decimals are
    ' REJECTED, not rounded (design §4): rounding money silently is the
    ' failure this whole mechanism exists to prevent.
    function to_minor(value, scale)
        t = trim(string(value))
        if t = "" then
            return { ok: false, minor: "", message: "empty money value" }
        end if
        neg = false
        if starts_with(t, "-") then
            neg = true
            t = mid(t, 1, len(t) - 1)
        else if starts_with(t, "+") then
            t = mid(t, 1, len(t) - 1)
        end if

        parts = split(t, ".")
        if count(parts) > 2 then
            return { ok: false, minor: "", message: "not a decimal number: '" + string(value) + "'" }
        end if
        whole = parts[0]
        frac = ""
        if count(parts) = 2 then
            frac = parts[1]
        end if
        if whole = "" then
            whole = "0"
        end if
        if not _digits_only(whole) then
            return { ok: false, minor: "", message: "not a decimal number: '" + string(value) + "'" }
        end if
        if frac != "" and not _digits_only(frac) then
            return { ok: false, minor: "", message: "not a decimal number: '" + string(value) + "'" }
        end if
        if len(frac) > scale then
            return { ok: false, minor: "", message: "value '" + string(value) + "' has " + string(len(frac)) + " decimal places; column scale is " + string(scale) + " (rejected, not rounded)" }
        end if
        while len(frac) < scale
            frac = frac + "0"
        end while
        minor = _strip_leading_zeros(whole + frac)
        if neg and minor != "0" then
            minor = "-" + minor
        end if
        return { ok: true, minor: minor, message: "" }
    end function

    function _sql_type(declared)
        if declared = "money" then
            return "INTEGER"
        end if
        if declared = "integer" then
            return "INTEGER"
        end if
        if declared = "real" then
            return "REAL"
        end if
        return "TEXT"
    end function

    ' Undeclared columns map: integer-looking -> INTEGER, numeric -> REAL,
    ' else TEXT (design §4).
    function infer_kind(samples)
        seen = false
        all_int = true
        all_num = true
        i = 0
        while i < count(samples)
            v = trim(string(samples[i]))
            if v != "" then
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
    ' scale; everything else is inferred from the fetched rows.
    function plan_columns(column_names, rows, declared)
        plan = []
        c = 0
        while c < count(column_names)
            nm = column_names[c]
            d = unknown
            if not is_unknown(declared) then
                d = declared[nm]
            end if
            if not is_unknown(d) and d["type"] = "money" then
                plan = concat(plan, [{ name: nm, kind: "money", scale: d["scale"] }])
            else
                samples = []
                r = 0
                while r < count(rows)
                    samples = concat(samples, [rows[r][c]])
                    r += 1
                end while
                plan = concat(plan, [{ name: nm, kind: infer_kind(samples), scale: 0 }])
            end if
            c += 1
        end while
        return plan
    end function

    function _quote_ident(nm)
        return chr(34) + replace(nm, chr(34), chr(34) + chr(34)) + chr(34)
    end function

    ' Materialize fetched rows into a staging file. Per-column scale lives in
    ' _gdash_meta inside the dataset file (design §4), so a reader needs
    ' nothing but the file to interpret its money columns.
    function materialize(path, table, plan, rows)
        on error goto next
        db = sqlite.connect(path)
        if error then
            return { ok: false, message: "cannot open staging file: " + path, rejected: 0 }
        end if

        defs = []
        i = 0
        while i < count(plan)
            defs = concat(defs, [_quote_ident(plan[i].name) + " " + _sql_type(plan[i].kind)])
            i += 1
        end while

        sqlite.exec(db, "drop table if exists " + _quote_ident(table))
        sqlite.exec(db, "create table " + _quote_ident(table) + " (" + join(defs, ", ") + ")")
        sqlite.exec(db, "drop table if exists _gdash_meta")
        sqlite.exec(db, "create table _gdash_meta (column_name text, kind text, scale integer)")
        if error then
            sqlite.close(db)
            return { ok: false, message: "cannot create dataset table", rejected: 0 }
        end if

        i = 0
        while i < count(plan)
            sqlite.exec(db, "insert into _gdash_meta values (?, ?, ?)", [plan[i].name, plan[i].kind, plan[i].scale])
            i += 1
        end while

        marks = []
        i = 0
        while i < count(plan)
            marks = concat(marks, ["?"])
            i += 1
        end while
        stmt = "insert into " + _quote_ident(table) + " values (" + join(marks, ", ") + ")"

        sqlite.begin(db)
        r = 0
        while r < count(rows)
            vals = []
            c = 0
            while c < count(plan)
                raw = rows[r][c]
                if plan[c].kind = "money" then
                    conv = to_minor(raw, plan[c].scale)
                    if not conv.ok then
                        sqlite.rollback(db)
                        sqlite.close(db)
                        ' A refusal, not a rounding. The whole refresh fails
                        ' and the previous dataset file stays untouched.
                        return { ok: false, message: "row " + string(r) + ", column '" + plan[c].name + "': " + conv.message, rejected: 1 }
                    end if
                    ' The minor-unit STRING binds into an INTEGER column as an
                    ' exact int64; binding a number would round past 2^53.
                    vals = concat(vals, [conv.minor])
                else
                    vals = concat(vals, [raw])
                end if
                c += 1
            end while
            sqlite.exec(db, stmt, vals)
            if error then
                sqlite.rollback(db)
                sqlite.close(db)
                return { ok: false, message: "insert failed at row " + string(r), rejected: 0 }
            end if
            r += 1
        end while
        sqlite.commit(db)
        sqlite.close(db)
        if error then
            return { ok: false, message: "commit failed", rejected: 0 }
        end if
        return { ok: true, message: "", rejected: 0 }
    end function

    ' Every dataset file carries its own _gdash_meta, and an UNQUALIFIED read
    ' of it across attached schemas resolves silently to `main` (finding
    ' G2-3) -- which would render one dataset's money column at another
    ' dataset's scale, with no error anywhere. So every metadata read is
    ' schema-qualified, and it is qualified here, inside the module, where no
    ' caller can forget to.
    function _meta_from(db, schema, into)
        out = into
        on error goto next
        rows = sqlite.query(db, "select column_name, scale from " + _quote_ident(schema) + "._gdash_meta where kind = 'money'")
        if error then
            return out
        end if
        i = 0
        while i < count(rows)
            out[rows[i].column_name] = rows[i].scale
            i += 1
        end while
        return out
    end function

    ' Scales for every money column reachable from this visual: the primary
    ' dataset's own, plus each attached sibling's. The primary is read LAST so
    ' it wins a name collision -- it is the dataset the visual named.
    function money_columns(path, attach)
        on error goto next
        db = sqlite.connect(path)
        if error then
            return {}
        end if
        out = {}
        names = keys(attach)
        i = 0
        while i < count(names)
            if _attach_one(db, names[i], attach[names[i]]) then
                out = _meta_from(db, names[i], out)
            end if
            i += 1
        end while
        out = _meta_from(db, "main", out)
        sqlite.close(db)
        return out
    end function

    function table_columns(path, table)
        on error goto next
        db = sqlite.connect(path)
        if error then
            return []
        end if
        rows = sqlite.query(db, "pragma table_info(" + _quote_ident(table) + ")")
        sqlite.close(db)
        if error then
            return []
        end if
        out = []
        i = 0
        while i < count(rows)
            out = concat(out, [rows[i].name])
            i += 1
        end while
        return out
    end function

    ' SQLite allows ten attached databases besides `main` (finding G2-4); the
    ' record validator refuses a dashboard with more datasets than that, so
    ' reaching the limit here means the validator was bypassed.
    function attach_limit()
        return 10
    end function

    function _attach_one(db, alias, file)
        on error goto next
        sqlite.exec(db, "attach database ? as " + _quote_ident(alias), [file])
        if error then
            return false
        end if
        return true
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
                cells = concat(cells, [string(row[c])])
                c += 1
            end while
            parts = concat(parts, [join(cells, chr(31))])
            r += 1
        end while
        return crypto.sha256_hex(join(parts, chr(30)))
    end function

    ' Run a visual query. `exact` names result columns whose values must not
    ' cross the gBASIC number boundary; each comes back additionally as
    ' <name>__text, cast in SQLite where the arithmetic was already exact.
    '
    ' `attach` maps a sibling dataset's name to its file. Unqualified table
    ' names resolve across attached schemas (finding G2-2), so a visual query
    ' joining two datasets reads exactly like one over a single dataset.
    function select_rows(path, sql, values, exact, attach)
        scanned = gdash_sql.scan(sql)
        args = gdash_sql.args_for(scanned, values)
        stmt = scanned.sql
        if count(exact) > 0 then
            casts = []
            i = 0
            while i < count(exact)
                casts = concat(casts, ["cast(" + _quote_ident(exact[i]) + " as text) as " + _quote_ident(exact[i] + "__text")])
                i += 1
            end while
            stmt = "select *, " + join(casts, ", ") + " from ( " + stmt + " )"
        end if

        on error goto next
        db = sqlite.connect(path)
        if error then
            return { ok: false, rows: [], message: "dataset not available" }
        end if
        anames = keys(attach)
        i = 0
        while i < count(anames)
            joined = _attach_one(db, anames[i], attach[anames[i]])
            i += 1
        end while
        rows = sqlite.query(db, stmt, args)
        if error then
            msg = error.message
            sqlite.close(db)
            return { ok: false, rows: [], message: msg }
        end if
        sqlite.close(db)
        return { ok: true, rows: rows, message: "" }
    end function

    ' The swap: one POSIX rename, and the version file bumps AFTER it, so a
    ' notified reader always finds complete data (design §3).
    function swap(staging, live)
        on error goto next
        atomic_replace(staging, live)
        if error then
            return { ok: false, message: error.message }
        end if
        return { ok: true, message: "" }
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
