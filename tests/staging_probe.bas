' For the shell runners: a dashboard's data is G-SQL tables now, not files a
' shell can test with -f, so this answers through the store.
'
'   staging_probe <db> <dataset> live     -> "live" or "none"
'   staging_probe <db> <dataset> staging  -> "staging" or "none"
'   staging_probe <db> <dataset> plant    -> writes a staging table, as a
'                                            crashed refresh child leaves one

program main(args)
    load gdash_store from "../src/gdash_store.bas"
    if count(args) < 3 then
        print to error "usage: staging_probe <db> <dataset> live|staging|plant"
        exit(2)
    end if
    db = args[0]
    ds = args[1]
    what = args[2]
    if what = "plant" then
        m = gdash_store.materialize(db, ds, gdash_store.plan_columns(["note"], [["x"]], {}), [["half-written"]])
        if m.ok then
            print("planted")
        else
            print("refused: " + m.message)
        end if
    else if what = "live" then
        if gdash_store.has_dataset(db, ds) then
            print("live")
        else
            print("none")
        end if
    else
        if gdash_store.has_staging(db, ds) then
            print("staging")
        else
            print("none")
        end if
    end if
end program
