' gdash — the audit log.
'
' One JSON object per line in <log_dir>/audit.log (design §6): greppable by an
' operator, parseable by anything, and appendable without reading what is
' already there.
'
' Nothing here may carry a credential. A profile is logged by NAME; its host,
' user and password are not the audit log's business and never appear in it
' (CLAUDE.md).
'
' THE OPERATOR'S STREAM (GDASH-17; gdash_saas_design.md §6). Each tenant's
' audit log is its own; an operator running hundreds needs one place to see
' sign-ins, refresh failures, refusals and spend across all of them, because
' with downtime tolerated a human is the failover. So the kinds below are
' also written, with the tenant's id, to the base deployment's events.log.
' The tenant is found from its own root's stamp, the way its limits are, so
' every entry point -- a request, the scheduler, the CLI -- reaches it.
' A question's text stays in the tenant's own log: it is the tenant's data.

library gdash_audit

    load gdash_paths from "gdash_paths.bas"
    load gdash_tenants from "gdash_tenants.bas"

    function operator_kinds()
        return ["login", "login.failed", "login.throttled", "login.unavailable", "identity.unavailable", "auth.config.invalid",
                "refresh.failed", "refresh.unit_failed", "refresh.deferred", "schedule.invalid",
                "publish", "publish.refused", "rollback", "theme.invalid",
                "ask", "ask.refused", "spend"]
    end function

    ' Fields the operator's stream leaves out, whatever the event.
    function _private()
        return ["question"]
    end function

    ' The base's events.log for a tenant's root, or "" for a single root,
    ' whose own audit log is already the operator's.
    function _operator_log(p)
        st = gdash_tenants.read_stamp(p)
        if not st.stamped or not st.ok or st.tenant = "" then
            return { path: "", tenant: "" }
        end if
        return { path: gdash_paths.events_log(gdash_tenants.base_of(p, st)), tenant: st.tenant }
    end function

    function _forward(p, line)
        dest = _operator_log(p)
        if dest.path = "" then
            return true
        end if
        out = { at: line["at"], tenant: dest.tenant }
        for each k in keys(line)
            if k != "at" and not contains(_private(), k) then
                out[k] = line[k]
            end if
        next
        made = gdash_paths.ensure_dir(gdash_paths.dir_of(dest.path))
        on error goto next
        f {file} = dest.path
        append(f, encode(out) + chr(10))
        if error then
            print to error "gdash: cannot write the operator's event log: " + error.message
            return false
        end if
        return true
    end function

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
        on error stop
        if contains(operator_kinds(), kind) then
            return _forward(p, line)
        end if
        return true
    end function

end library
