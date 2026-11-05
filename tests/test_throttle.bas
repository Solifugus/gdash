' Slowing down a password guesser.
'
' The clock is an argument throughout, so nothing here sleeps. A test that
' waits is a test somebody eventually deletes.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_throttle from "../src/gdash_throttle.bas"

    s = gdash_test.suite("throttle")
    root = args[0]
    p = gdash_paths.roles(root)
    lim = gdash_throttle.throttle_limits()

    ' Start from no counters, whatever the harness handed us. The runner gives
    ' each suite a fresh root, but a test that only passes because of that is a
    ' test that cannot be run on its own -- and running one on its own is
    ' exactly what you do when it fails. Learned in test_theme and not carried
    ' forward until this suite failed the same way.
    on error goto next
    for each stale in files(gdash_paths.throttle_dir(p))
        junk {file} = gdash_paths.throttle_dir(p) + "/" + stale.name
        delete(junk)
    next
    ' A fresh root has no directory to list; that is the case being tolerated,
    ' and an error left unacknowledged is reported when the program exits.
    if error then
    end if

    ' --- the grace: a typo is free ---------------------------------------
    ' `grace` counts ATTEMPTS, and the wait is read before the next attempt is
    ' made -- so with a grace of three, two recorded failures still cost
    ' nothing and the third means the next attempt waits. Written out rather
    ' than looped, because the boundary is the whole point and a loop hides it.
    st = gdash_throttle.no_attempts()
    s = gdash_test.eq(s, gdash_throttle.delay_remaining(st, 1000, lim), 0, "no failures, no wait")
    st = gdash_throttle.after_failure(st, 1000, lim)
    s = gdash_test.eq(s, gdash_throttle.delay_remaining(st, 1000, lim), 0, "one failure still costs nothing")
    st = gdash_throttle.after_failure(st, 1000, lim)
    s = gdash_test.eq(s, gdash_throttle.delay_remaining(st, 1000, lim), 0, "nor does two -- a typo is free")

    ' --- and then it costs, doubling ---------------------------------------
    st = gdash_throttle.after_failure(st, 1000, lim)
    s = gdash_test.eq(s, gdash_throttle.delay_remaining(st, 1000, lim), 1, "the third exhausts the grace and costs a second")
    st = gdash_throttle.after_failure(st, 1000, lim)
    s = gdash_test.eq(s, gdash_throttle.delay_remaining(st, 1000, lim), 2, "then two")
    st = gdash_throttle.after_failure(st, 1000, lim)
    s = gdash_test.eq(s, gdash_throttle.delay_remaining(st, 1000, lim), 4, "then four")

    ' --- IT NEVER LOCKS ---------------------------------------------------
    '
    ' A permanent lockout is a denial-of-service against a named colleague that
    ' anyone can trigger by typing their name wrong, and on an intranet that
    ' name is easy to guess. So the delay stops growing.
    i = 0
    while i < 40
        st = gdash_throttle.after_failure(st, 1000, lim)
        i += 1
    end while
    s = gdash_test.eq(s, gdash_throttle.delay_remaining(st, 1000, lim), lim.cap, "forty more failures reach the ceiling")
    s = gdash_test.ok(s, gdash_throttle.delay_remaining(st, 1000, lim) <= lim.cap, "and never exceed it")
    s = gdash_test.eq(s, gdash_throttle.delay_remaining(st, 1000 + lim.cap, lim), 0, "so the account is always reachable again")

    ' --- and it forgets ----------------------------------------------------
    s = gdash_test.eq(s, gdash_throttle.delay_remaining(st, 1000 + lim.forget, lim), 0, "silence for the forget window clears the wait")
    revived = gdash_throttle.after_failure(st, 1000 + lim.forget, lim)
    s = gdash_test.eq(s, revived.failures, 1, "and a failure after it starts the count over")

    ' --- the key ------------------------------------------------------------
    k = gdash_throttle.key_for("ada")
    s = gdash_test.eq(s, len(k), 64, "a key is a fixed-length hash")
    s = gdash_test.ok(s, not contains(k, "ada"), "carrying no trace of the username")
    s = gdash_test.eq(s, k, gdash_throttle.key_for("  ADA  "), "case and spacing do not make a second account")
    s = gdash_test.ok(s, k != gdash_throttle.key_for("bo"), "and two names are two keys")
    ' A username is not a safe filename; hashing is what makes it one.
    s = gdash_test.ok(s, not contains(gdash_throttle.key_for("../../etc/passwd"), "/"), "a name that is a path becomes a key that is not")

    ' --- the file half ------------------------------------------------------
    ka = gdash_throttle.key_for("ada")
    kb = gdash_throttle.key_for("bo")
    s = gdash_test.eq(s, gdash_throttle.read_attempts(p, ka).failures, 0, "an unknown name has no record")
    stored = gdash_throttle.write_attempts(p, ka, { failures: 5, last: 1000 })
    s = gdash_test.ok(s, stored, "a record is written")
    s = gdash_test.eq(s, gdash_throttle.read_attempts(p, ka).failures, 5, "and read back")
    s = gdash_test.eq(s, gdash_throttle.read_attempts(p, kb).failures, 0, "one name's failures are not another's")

    ' A record gdash cannot make sense of is no record, not a raise -- the
    ' class G7-12 swept out of every other reader.
    bad {file} = gdash_paths.throttle_file(p, kb)
    write(bad, "[1, 2, 3]")
    s = gdash_test.eq(s, gdash_throttle.read_attempts(p, kb).failures, 0, "a counter file of the wrong shape reads as no record")
    write(bad, encode({ format: 1, failures: "many", last: "never" }))
    s = gdash_test.eq(s, gdash_throttle.read_attempts(p, kb).failures, 0, "and so does one with text where numbers belong")

    cleared = gdash_throttle.clear_attempts(p, ka)
    s = gdash_test.eq(s, gdash_throttle.read_attempts(p, ka).failures, 0, "a success clears the record")

    ' --- the sweep ----------------------------------------------------------
    stored = gdash_throttle.write_attempts(p, ka, { failures: 9, last: 1000 })
    stored = gdash_throttle.write_attempts(p, kb, { failures: 9, last: 500000 })
    gone = gdash_throttle.sweep_attempts(p, 500000, lim)
    s = gdash_test.ok(s, gone >= 1, "the sweep forgets a stale counter")
    s = gdash_test.eq(s, gdash_throttle.read_attempts(p, ka).failures, 0, "removing the one past its window")
    s = gdash_test.eq(s, gdash_throttle.read_attempts(p, kb).failures, 9, "and leaving the one still counting")

    exit(gdash_test.report(s))
end program
