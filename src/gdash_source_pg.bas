' gdash — the Postgres source.
'
' The child's whole job is to block, so synchronous pg is right (design §3).
' Values come back as strings: pg returns numeric/bigint as strings to avoid
' float loss, and gdash keeps them that way all the way into minor units.

library gdash_source_pg

    load pg

    function fetch(profile, sql)
        on error goto next
        conn = pg.connect({ host: profile["host"], port: profile["port"], database: profile["database"], user: profile["user"], password: profile["password"] })
        if error then
            ' The message may name the host but never the password, which is
            ' why the profile is not interpolated into it.
            return { ok: false, columns: [], rows: [], message: "cannot connect to source: " + error.message }
        end if
        rows = pg.query(conn, sql)
        if error then
            msg = error.message
            pg.close(conn)
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
                    vals = concat(vals, [""])
                else
                    vals = concat(vals, [string(v)])
                end if
                c += 1
            end while
            out = concat(out, [vals])
            i += 1
        end while
        return { ok: true, columns: cols, rows: out, message: "" }
    end function

end library
