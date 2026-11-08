' Holds refresh slots from ANOTHER process, the way a running refresh would,
' so a test can see the next refresh deferred. Usage:
'   hold_slots <marker-file> <seconds> <slot-file>...
' Writes the marker once every slot is held, then holds them for <seconds>
' or until the marker is deleted, whichever is first.

program main(args)
    if count(args) < 3 then
        print to error "usage: hold_slots <marker> <seconds> <slot>..."
        exit(2)
    end if
    held = []
    i = 2
    while i < count(args)
        f {file} = args[i]
        if not exists(f) then
            write(f, "")
        end if
        if not lock(f, { wait: false }) then
            print to error "slot already held: " + args[i]
            exit(3)
        end if
        held = append(held, f)
        i += 1
    end while
    m {file} = args[0]
    write(m, "held")
    t0 = monotonic()
    while monotonic() - t0 < number(args[1]) and exists(m)
        sleep(0.05)
    end while
    exit(0)
end program
