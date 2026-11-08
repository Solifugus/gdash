' gdash — the scheduler.
'
' A separate program, and that is the finding rather than a preference. There
' is no server-side timer to hang a periodic task on: the `server` block
' admits one hook (`on drain`), and `main` must return for the event loop to
' run at all. Worse, `serve` with `workers: N` spawns N copies of the whole
' program, so `main` runs N+1 times -- a scheduler started from the server
' would multiply with the worker count, silently, whenever an operator tuned
' it (finding G2-1).
'
' So: one process, one loop, one call into the same pass the CLI runs. It
' shares nothing with the workers but the filesystem, which is how every other
' global event in gdash travels (design §5).
'
' usage: gdash_scheduler.bas --root <dir> [--every <seconds>] [--once]

program main(args)
    load gdash_shadow from "gdash_shadow.bas"
    load gdash_paths from "gdash_paths.bas"
    load gdash_refresh from "gdash_refresh.bas"
    load gdash_tenants from "gdash_tenants.bas"

    ' A bare-name `load` searches THIS directory, recursively, before the
    ' stdlib, so a stray crypto.bas here would be the password hasher. Loads
    ' resolve before the body runs, so this cannot prevent the load -- but a
    ' gBASIC library body defines functions rather than running them, so a
    ' shadow is inert until something calls it, and gdash refuses first.
    shadows = gdash_shadow.enforce()

    p = gdash_paths.from_args(args)

    ' One scheduler per tenant (gdash_saas_design.md §4), as a systemd
    ' template unit: `gdash-scheduler@acme` runs this with `--tenant acme`.
    ' Separate processes cannot stall each other, where a shared pool would
    ' need fairness logic to approximate that.
    j = 0
    while j < count(args)
        if args[j] = "--tenant" and j + 1 < count(args) then
            tr = gdash_tenants.roles_for(p, args[j + 1])
            if not tr.ok then
                print to error "gdash scheduler: " + tr.message
                exit(2)
            end if
            p = tr.p
        end if
        j += 1
    end while

    period = 15
    once = false
    i = 0
    while i < count(args)
        if args[i] = "--every" and i + 1 < count(args) then
            period = default(number(args[i + 1]), 15)
        end if
        if args[i] = "--once" then
            once = true
        end if
        i += 1
    end while
    if period < 1 then
        period = 1
    end if

    print("gdash scheduler: " + gdash_paths.describe(p))
    print("gdash scheduler: every " + string(period) + "s")

    ' The tick period is how often policies are CONSIDERED, not how often
    ' anything is fetched: `every: 300` means five minutes whatever this is
    ' set to. A short tick costs a directory listing and a few small reads.
    going = true
    while going
        result = gdash_refresh.pass(p)
        j = 0
        while j < count(result.notes)
            print(result.notes[j])
            j += 1
        end while
        if once then
            going = false
        else
            sleep(period)
        end if
    end while
    exit(0)
end program
