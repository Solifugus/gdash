' gdash — the audit log.
'
' One JSON object per line in <log_dir>/audit.log (design §6): greppable by an
' operator, parseable by anything, and appendable without reading what is
' already there.
'
' Nothing here may carry a credential. A profile is logged by NAME; its host,
' user and password are not the audit log's business and never appear in it
' (CLAUDE.md).

library gdash_audit

    load gdash_paths from "gdash_paths.bas"

    ' Best-effort by design: a dashboard that cannot write its audit line is
    ' still a dashboard, and failing a refresh because the log directory is
    ' read-only would make the logging more fragile than the thing it logs.
    ' The failure is reported to stderr, where an operator's journal has it.
    function event(p, kind, fields)
        made = gdash_paths.ensure_dir(p.log_dir)
        line = { at: epoch(), event: kind }
        names = keys(fields)
        i = 0
        while i < count(names)
            line[names[i]] = fields[names[i]]
            i += 1
        end while
        on error goto next
        f {file} = gdash_paths.audit_log(p)
        append(f, encode(line) + chr(10))
        if error then
            print to error "gdash: cannot write audit log: " + error.message
            return false
        end if
        return true
    end function

end library
