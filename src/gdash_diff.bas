' gdash — the snapshot diff.
'
' Design §7 calls the version diff a headline feature for free: "what changed
' between the numbers the CFO saw Tuesday and today". Free is doing some work
' in that sentence, but only some -- the records are text and diffable because
' of the format ruling, and this is the part that has to be written.
'
' Hand-rolled rather than shelled out to diff(1) (GDASH-3 step-0 V3). A
' product whose pitch is "stand it up in an afternoon" should not have a
' headline feature that depends on a binary being in the image, and design
' §6's own deployment guidance -- ProtectSystem=strict, a dedicated user, a
' minimal container -- describes exactly the environments where assuming one
' is least safe.
'
' This module uses `append` rather than the `concat` the rest of gdash reaches
' for. That is deliberate and local: `append` mutates in place, and the LCS
' table is the one place in gdash where an O(n) copy per element would turn a
' small quadratic into a large one.

library gdash_diff

    ' Beyond this many table cells, fall back to "replaced wholesale" rather
    ' than build the table. A record whose middle is this large has not been
    ' edited, it has been rewritten, and a line-by-line diff of it would be
    ' noise a reader has to wade through anyway.
    function cell_budget()
        return 250000
    end function

    function text_lines(text)
        t = replace(string(text), chr(13), "")
        parts = split(t, chr(10))
        n = count(parts)
        ' A trailing newline yields a final empty element that is not a line.
        if n > 0 and parts[n - 1] = "" then
            out = []
            i = 0
            while i < n - 1
                append(out, parts[i])
                i += 1
            end while
            return out
        end if
        return parts
    end function

    function _common_prefix(a, b)
        i = 0
        while i < count(a) and i < count(b)
            if a[i] != b[i] then
                return i
            end if
            i += 1
        end while
        return i
    end function

    function _common_suffix(a, b, floor_a, floor_b)
        k = 0
        while count(a) - 1 - k >= floor_a and count(b) - 1 - k >= floor_b
            if a[count(a) - 1 - k] != b[count(b) - 1 - k] then
                return k
            end if
            k += 1
        end while
        return k
    end function

    function _slice(a, from, upto)
        out = []
        i = from
        while i < upto
            append(out, a[i])
            i += 1
        end while
        return out
    end function

    function _wholesale(ma, mb)
        script = []
        i = 0
        while i < count(ma)
            append(script, { op: "-", text: ma[i] })
            i += 1
        end while
        i = 0
        while i < count(mb)
            append(script, { op: "+", text: mb[i] })
            i += 1
        end while
        return script
    end function

    ' Longest common subsequence, filled from the end so the forward walk can
    ' read it. Only the middle reaches here: a publish that changes a title
    ' leaves a prefix and suffix that are trimmed before this is called, so the
    ' table is usually a few cells.
    function _lcs_script(ma, mb)
        na = count(ma)
        nb = count(mb)
        if na = 0 or nb = 0 then
            return _wholesale(ma, mb)
        end if
        if na * nb > cell_budget() then
            return _wholesale(ma, mb)
        end if

        tbl = []
        r = 0
        while r <= na
            row = []
            c = 0
            while c <= nb
                append(row, 0)
                c += 1
            end while
            append(tbl, row)
            r += 1
        end while

        i = na - 1
        while i >= 0
            j = nb - 1
            while j >= 0
                if ma[i] = mb[j] then
                    tbl[i][j] = tbl[i + 1][j + 1] + 1
                else if tbl[i + 1][j] >= tbl[i][j + 1] then
                    tbl[i][j] = tbl[i + 1][j]
                else
                    tbl[i][j] = tbl[i][j + 1]
                end if
                j -= 1
            end while
            i -= 1
        end while

        script = []
        i = 0
        j = 0
        while i < na and j < nb
            if ma[i] = mb[j] then
                append(script, { op: " ", text: ma[i] })
                i += 1
                j += 1
            else if tbl[i + 1][j] >= tbl[i][j + 1] then
                append(script, { op: "-", text: ma[i] })
                i += 1
            else
                append(script, { op: "+", text: mb[j] })
                j += 1
            end if
        end while
        while i < na
            append(script, { op: "-", text: ma[i] })
            i += 1
        end while
        while j < nb
            append(script, { op: "+", text: mb[j] })
            j += 1
        end while
        return script
    end function

    ' The full edit script over both texts, as [{ op, text }] with op in
    ' " ", "-", "+".
    function script(a_text, b_text)
        a = text_lines(a_text)
        b = text_lines(b_text)
        pre = _common_prefix(a, b)
        suf = _common_suffix(a, b, pre, pre)

        out = []
        i = 0
        while i < pre
            append(out, { op: " ", text: a[i] })
            i += 1
        end while

        ma = _slice(a, pre, count(a) - suf)
        mb = _slice(b, pre, count(b) - suf)
        mid = _lcs_script(ma, mb)
        i = 0
        while i < count(mid)
            append(out, mid[i])
            i += 1
        end while

        i = count(a) - suf
        while i < count(a)
            append(out, { op: " ", text: a[i] })
            i += 1
        end while
        return out
    end function

    function changed(a_text, b_text)
        sc = script(a_text, b_text)
        i = 0
        while i < count(sc)
            if sc[i].op != " " then
                return true
            end if
            i += 1
        end while
        return false
    end function

    ' Unified diff. Identical texts produce an empty body rather than a header
    ' with no hunks -- "nothing changed" reads better as nothing.
    function unified(a_text, b_text, a_label, b_label, ctx)
        sc = script(a_text, b_text)
        if not changed(a_text, b_text) then
            return ""
        end if

        ' Which script entries are near a change, and therefore printed.
        keep = []
        i = 0
        while i < count(sc)
            append(keep, false)
            i += 1
        end while
        i = 0
        while i < count(sc)
            if sc[i].op != " " then
                lo = i - ctx
                if lo < 0 then
                    lo = 0
                end if
                hi = i + ctx
                if hi > count(sc) - 1 then
                    hi = count(sc) - 1
                end if
                k = lo
                while k <= hi
                    keep[k] = true
                    k += 1
                end while
            end if
            i += 1
        end while

        out = ["--- " + a_label, "+++ " + b_label]
        i = 0
        a_line = 1
        b_line = 1
        while i < count(sc)
            if not keep[i] then
                if sc[i].op != "+" then
                    a_line += 1
                end if
                if sc[i].op != "-" then
                    b_line += 1
                end if
                i += 1
            else
                ' One hunk: every kept entry from here until the next gap.
                a_start = a_line
                b_start = b_line
                a_count = 0
                b_count = 0
                body = []
                j = i
                while j < count(sc) and keep[j]
                    append(body, sc[j].op + sc[j].text)
                    if sc[j].op != "+" then
                        a_count += 1
                        a_line += 1
                    end if
                    if sc[j].op != "-" then
                        b_count += 1
                        b_line += 1
                    end if
                    j += 1
                end while
                append(out, "@@ -" + string(a_start) + "," + string(a_count) + " +" + string(b_start) + "," + string(b_count) + " @@")
                k = 0
                while k < count(body)
                    append(out, body[k])
                    k += 1
                end while
                i = j
            end if
        end while
        return join(out, chr(10)) + chr(10)
    end function

end library
