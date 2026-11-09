' gdash — the Postgres source.
'
' The child's whole job is to block, so synchronous pg is right (design §3).
' Values come back as strings: pg returns numeric/bigint as strings to avoid
' float loss, and gdash keeps them that way until G-SQL reads each into its
' column's kind -- money exactly (GDASH-20).

library gdash_source_pg

    load pg

    ' `max_rows` (0 for none) is the ceiling's row cap (GDASH-16, gbasic B2):
    ' libpq reads in single-row mode and the query is cancelled one row past
    ' it, so a query far over the ceiling is refused having held at most that
    ' many rows, rather than all of them.
    function fetch(profile, sql, max_rows)
        on error goto next
        conn = pg.connect({ host: profile["host"], port: profile["port"], database: profile["database"], user: profile["user"], password: profile["password"] })
        if error then
            ' The message may name the host but never the password, which is
            ' why the profile is not interpolated into it.
            return { ok: false, columns: [], rows: [], message: "cannot connect to source: " + error.message }
        end if
        if max_rows > 0 then
            rows = pg.query(conn, sql, [], { max_rows: max_rows })
        else
            rows = pg.query(conn, sql)
        end if
        if error then
            msg = error.message
            capped = string(default(error.details["code"], "")) = "MAX_ROWS"
            pg.close(conn)
            if capped then
                return { ok: false, capped: true, columns: [], rows: [], message: "the query returned more than " + string(max_rows) + " rows, above this site's ceiling; narrow the query or aggregate it at the source" }
            end if
            return { ok: false, columns: [], rows: [], message: "source query failed: " + msg }
        end if
        pg.close(conn)

        if count(rows) = 0 then
            return { ok: true, columns: [], rows: [], message: "" }
        end if
        cols = keys(rows[0])
        out = []
        i = 0
        while i < count(rows)
            vals = []
            c = 0
            while c < count(cols)
                v = rows[i][cols[c]]
                if is_unknown(v) or is_nothing(v) then
                    vals = append(vals, "")
                else
                    vals = append(vals, string(v))
                end if
                c += 1
            end while
            out = append(out, vals)
            i += 1
        end while
        return { ok: true, columns: cols, rows: out, message: "" }
    end function

end library
