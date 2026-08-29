' gdash — SQL binding scanner.
'
' One scan, two consumers (design §2, "derived, never declared"): the set of
' `:name` bindings in a query IS the dependency graph, and the same pass emits
' the positional rewrite the platform requires. `sqlite.query` binds `?` with
' an array only (finding F2), so gdash owns the `:name` -> `?` rewrite.
'
' The scanner must not see a binding inside a string literal, a quoted
' identifier, or a comment. Getting that wrong corrupts queries silently
' rather than raising, which is why it carries adverse tests.

library gdash_sql

    function _ident_start(c)
        if c = "" then
            return false
        end if
        return contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_", c)
    end function

    function _ident_char(c)
        if c = "" then
            return false
        end if
        return contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789", c)
    end function

    ' Returns { names: [...unique, first-appearance order],
    '           order: [...one name per '?', left to right],
    '           sql:   the rewritten text }
    function scan(sql)
        names = []
        order = []
        chunks = []
        i = 0
        n = len(sql)
        nl = chr(10)

        while i < n
            c = mid(sql, i, 1)
            two = mid(sql, i, 2)

            if two = "--" then
                ' line comment: copy through to end of line
                while i < n and mid(sql, i, 1) != nl
                    chunks = concat(chunks, [mid(sql, i, 1)])
                    i += 1
                end while

            else if two = "/*" then
                ' block comment: copy through to the closing delimiter
                chunks = concat(chunks, ["/*"])
                i += 2
                while i < n and mid(sql, i, 2) != "*/"
                    chunks = concat(chunks, [mid(sql, i, 1)])
                    i += 1
                end while
                if i < n then
                    chunks = concat(chunks, ["*/"])
                    i += 2
                end if

            else if c = "'" or c = chr(34) then
                ' string literal or quoted identifier; '' and "" escape the
                ' quote by doubling, which this handles by copying the pair
                q = c
                chunks = concat(chunks, [q])
                i += 1
                while i < n
                    d = mid(sql, i, 1)
                    if d = q then
                        if mid(sql, i + 1, 1) = q then
                            chunks = concat(chunks, [q, q])
                            i += 2
                        else
                            chunks = concat(chunks, [q])
                            i += 1
                            break
                        end if
                    else
                        chunks = concat(chunks, [d])
                        i += 1
                    end if
                end while

            else if c = ":" then
                if mid(sql, i, 2) = "::" then
                    ' a cast, not a binding
                    chunks = concat(chunks, ["::"])
                    i += 2
                else if _ident_start(mid(sql, i + 1, 1)) then
                    j = i + 1
                    nm = ""
                    while j < n and _ident_char(mid(sql, j, 1))
                        nm = nm + mid(sql, j, 1)
                        j += 1
                    end while
                    if not contains(names, nm) then
                        names = concat(names, [nm])
                    end if
                    order = concat(order, [nm])
                    chunks = concat(chunks, ["?"])
                    i = j
                else
                    chunks = concat(chunks, [c])
                    i += 1
                end if

            else
                chunks = concat(chunks, [c])
                i += 1
            end if
        end while

        return { names: names, order: order, sql: join(chunks, "") }
    end function

    ' The dependency graph for one query: which params it binds.
    function bindings(sql)
        return scan(sql).names
    end function

    ' Build the positional argument array for a rewritten query.
    function args_for(scanned, values)
        out = []
        i = 0
        while i < count(scanned.order)
            nm = scanned.order[i]
            out = concat(out, [values[nm]])
            i += 1
        end while
        return out
    end function

    ' Dataset names become table names, so they must be legal SQL identifiers
    ' (design §2).
    function legal_identifier(nm)
        if nm = "" then
            return false
        end if
        if not _ident_start(mid(nm, 0, 1)) then
            return false
        end if
        i = 1
        while i < len(nm)
            if not _ident_char(mid(nm, i, 1)) then
                return false
            end if
            i += 1
        end while
        return true
    end function

end library
