' gdash — the ODBC source.
'
' One more ORIGIN, not a second store. gdash stages every dataset into SQLite
' and runs every visual query there (design §3); ODBC joins `postgres` behind
' the same seam, and neither the staging store nor the record format changes.
'
' Values come back as strings, which is the whole reason this is safe: the
' module returns DECIMAL, NUMERIC and BIGINT as text on purpose, because a
' gBASIC number is a double and DECIMAL(19,4) does not fit in fifteen
' significant digits. `pg` answers numeric and bigint the same way, so gdash's
' money path -- text all the way into INTEGER minor units (design §4) -- needs
' no special case here (finding G9-2).
'
' THE CONNECTION STRING IS A CREDENTIAL. It carries PWD= and it must not reach
' an error message, a log line, a record or a viewer. The driver's own message
' was checked and does not leak it (G9-4), but a driver is third-party code and
' the next one may be less careful, so nothing here interpolates the profile
' into anything and the suite asserts the result.

library gdash_source_odbc

    ' `load odbc` is inside the functions that speak to a driver rather than at
    ' the library level, so a gbasic built without unixODBC still loads gdash
    ' and fails only when an ODBC profile is actually used -- guarded, with a
    ' message. It also lets the hermetic suite test everything up to the wire
    ' on a host with no drivers at all. Same shape as gdash_auth_ldap.

    ' A connection string, however the profile spells it. `dsn` is the older
    ' shape an operator with a configured odbc.ini expects; `connection` is the
    ' one that works on a host with drivers and no DSNs, which step-0 found is
    ' the normal case (G9-3).
    function connection_string(profile)
        c = trim(string(default(profile["connection"], "")))
        if c != "" then
            return c
        end if
        d = trim(string(default(profile["dsn"], "")))
        if d = "" then
            return ""
        end if
        return "DSN=" + d
    end function

    function fetch(profile, sql)
        target = connection_string(profile)
        if target = "" then
            return { ok: false, columns: [], rows: [], message: "odbc profile has neither 'connection' nor 'dsn'" }
        end if

        on error goto next
        load odbc
        if error then
            return { ok: false, columns: [], rows: [], message: "this build has no odbc support" }
        end if
        conn = odbc.connect(target)
        if error then
            ' The driver's message names a host and a SQLSTATE. The connection
            ' string is NOT added to it: it carries the password.
            return { ok: false, columns: [], rows: [], message: "cannot connect to source: " + error.message }
        end if

        rows = odbc.query(conn, sql, [])
        if error then
            msg = error.message
            closed = odbc.close(conn)
            return { ok: false, columns: [], rows: [], message: "source query failed: " + msg }
        end if
        closed = odbc.close(conn)

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
                    ' SQL NULL is `nothing` here and the empty string in the
                    ' seam, exactly as the Postgres source has it -- so a NULL
                    ' means the same thing whichever origin it came from.
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

    ' What `gdash source check` reports. Never the connection string.
    function describe_drivers()
        on error goto next
        load odbc
        if error then
            return []
        end if
        got = odbc.drivers()
        if error then
            return []
        end if
        names = []
        i = 0
        while i < count(got)
            names = append(names, string(got[i].name))
            i += 1
        end while
        return names
    end function

    function describe_sources()
        on error goto next
        load odbc
        if error then
            return []
        end if
        got = odbc.sources()
        if error then
            return []
        end if
        names = []
        i = 0
        while i < count(got)
            names = append(names, string(got[i].name))
            i += 1
        end while
        return names
    end function

end library
