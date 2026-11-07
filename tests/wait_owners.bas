' For the shell runners' scratch-clean: wait, with a bound, until no G-SQL
' owner holds any database under a directory, and say which still is.
'
'   wait_owners <dir> <seconds>     exit 0 when none is held, 1 naming them
'
' The owners a suite starts belong to processes long gone by cleanup -- server
' workers, refresh children, CLI calls -- so no program is left to close and
' wait. gsql.wait_for_owner asks the store's lock instead, which an owner
' releases after its final write (gbasic 0424a49, GDASH-20). A database is a
' directory whose name ends in `.gsql`; gdash's are `data.gsql`, and the
' suites' own probes use other names, so every such directory is asked.

function databases_under(dir)
    out = []
    on error goto next
    entries = folders(dir)
    if error then
        return out
    end if
    for each e in entries
        path = dir + "/" + e.name
        if ends_with(e.name, ".gsql") then
            out = append(out, path)
        else
            out = concat(out, databases_under(path))
        end if
    next
    return out
end function

program main(args)
    load gsql
    if count(args) < 2 then
        print to error "usage: wait_owners <dir> <seconds>"
        exit(2)
    end if
    held = []
    for each db in databases_under(args[0])
        if not gsql.wait_for_owner(db, number(args[1])) then
            held = append(held, db)
        end if
    next
    if count(held) > 0 then
        print to error "G-SQL owners still hold: " + join(held, ", ")
        exit(1)
    end if
    exit(0)
end program
