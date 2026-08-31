' Sessions, against a store gdash does not ship (design of the seam, G4-8) and
' a clock that is an argument. Nothing here sleeps and nothing here is a file
' gdash_session knows about.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_session from "../src/gdash_session.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load store_double from "store_double.bas"

    s = gdash_test.suite("session")
    root = args[0]
    made = gdash_paths.ensure_dir(root)
    st = store_double.store(root + "/sessions.json")
    lim = gdash_session.limits()

    ' --- ids ---
    a = gdash_session.mint_id()
    b = gdash_session.mint_id()
    s = gdash_test.ok(s, a != b, "two minted ids differ")
    s = gdash_test.ok(s, gdash_session.legal_id(a), "a minted id is legal")
    s = gdash_test.ok(s, not gdash_session.legal_id(""), "empty is not an id")
    s = gdash_test.ok(s, not gdash_session.legal_id("../../etc/passwd"), "a path is not an id")
    s = gdash_test.ok(s, not gdash_session.legal_id("abc.json"), "a dot is not in the alphabet")
    s = gdash_test.ok(s, not gdash_session.legal_id("a/b"), "nor is a separator")

    ' --- create and resolve ---
    c = gdash_session.create(st, "ada", 1000)
    s = gdash_test.ok(s, c.ok, "a session is created -- " + c.message)
    s = gdash_test.eq(s, c.session.user, "ada", "carrying its user")
    got = gdash_session.active(st, c.session.id, 1000, lim)
    s = gdash_test.ok(s, got.ok, "and resolves")
    s = gdash_test.eq(s, got.session.user, "ada", "to the same user")

    ' A session that was never created is simply absent.
    s = gdash_test.ok(s, not gdash_session.active(st, gdash_session.mint_id(), 1000, lim).ok, "an unknown id resolves to nothing")
    s = gdash_test.ok(s, not gdash_session.active(st, "../../etc/passwd", 1000, lim).ok, "and so does a path")

    ' --- expiry: absolute and idle, both, against a fabricated clock ---
    ' The two caps are independent, so each is tested with the other held out
    ' of the way: an ACTIVE session, near its absolute age, is the only thing
    ' the absolute cap is about.
    function place(store, id, user, created, seen)
        return store.put(store.ctx, id, { format: 1, id: id, user: user, created: created, seen: seen })
    end function

    aid = gdash_session.mint_id()
    placed = place(st, aid, "bo", 1000, 1000 + lim.absolute - 2)
    s = gdash_test.ok(s, gdash_session.active(st, aid, 1000 + lim.absolute - 1, lim).ok, "one second inside the absolute age, still active: alive")
    aid2 = gdash_session.mint_id()
    placed = place(st, aid2, "bo", 1000, 1000 + lim.absolute - 1)
    r = gdash_session.active(st, aid2, 1000 + lim.absolute, lim)
    s = gdash_test.ok(s, not r.ok, "exactly at the absolute age: gone, however active")
    s = gdash_test.eq(s, r.reason, "no session", "and an expired session reads exactly like a missing one")
    s = gdash_test.ok(s, is_unknown(st.get(st.ctx, aid2)), "an expired session is removed, not merely refused")

    idle = gdash_session.create(st, "cy", 1000)
    s = gdash_test.ok(s, gdash_session.active(st, idle.session.id, 1000 + lim.idle - 1, lim).ok, "one second inside the idle age: alive")
    idle2 = gdash_session.create(st, "cy", 1000)
    s = gdash_test.ok(s, not gdash_session.active(st, idle2.session.id, 1000 + lim.idle, lim).ok, "exactly at the idle age: gone")

    ' Activity moves the idle clock, so a busy session outlives the idle age.
    busy = gdash_session.create(st, "dee", 1000)
    t = 1000
    while t < 1000 + lim.idle * 2
        alive = gdash_session.active(st, busy.session.id, t, lim)
        t += lim.idle - 10
    end while
    s = gdash_test.ok(s, gdash_session.active(st, busy.session.id, t, lim).ok, "a session used regularly outlives the idle timeout")

    ' ...but not the absolute one, however busy.
    s = gdash_test.ok(s, not gdash_session.active(st, busy.session.id, 1000 + lim.absolute + 1, lim).ok, "and still dies at the absolute age")

    ' The last-seen write is throttled: it must not happen on every read.
    quiet = gdash_session.create(st, "eve", 1000)
    r1 = gdash_session.active(st, quiet.session.id, 1000 + lim.touch_after - 1, lim)
    s = gdash_test.eq(s, r1.session.seen, 1000, "a read inside the touch window does not rewrite last-seen")
    r2 = gdash_session.active(st, quiet.session.id, 1000 + lim.touch_after, lim)
    s = gdash_test.eq(s, r2.session.seen, 1000 + lim.touch_after, "a read past it does")

    ' --- regeneration on privilege change (the fixation defence) ---
    before = gdash_session.create(st, "", 2000)
    after = gdash_session.regenerate(st, before.session.id, 2000)
    s = gdash_test.ok(s, after.ok, "a session regenerates")
    s = gdash_test.ok(s, after.session.id != before.session.id, "the id a viewer held before is never the id they hold after")
    s = gdash_test.ok(s, is_unknown(st.get(st.ctx, before.session.id)), "and the old id is destroyed, not left valid")
    s = gdash_test.ok(s, gdash_session.active(st, after.session.id, 2000, lim).ok, "the new one works")

    ' Regenerating an id that never existed still yields a usable session --
    ' a viewer with a stale cookie logging in must not be refused for it.
    orphan = gdash_session.regenerate(st, gdash_session.mint_id(), 2000)
    s = gdash_test.ok(s, orphan.ok, "regenerating an unknown id still produces a session")

    ' --- destroy ---
    doomed = gdash_session.create(st, "fay", 3000)
    s = gdash_test.ok(s, gdash_session.destroy(st, doomed.session.id), "a session is destroyed")
    s = gdash_test.ok(s, not gdash_session.active(st, doomed.session.id, 3000, lim).ok, "and does not resolve after")
    s = gdash_test.ok(s, not gdash_session.destroy(st, "../../x"), "destroying a path is refused")

    ' --- sweep ---
    keep = gdash_session.create(st, "gil", 9000)
    swept = gdash_session.sweep(st, 9000, lim)
    s = gdash_test.ok(s, swept > 0, "the sweep removes what time has expired")
    s = gdash_test.ok(s, gdash_session.active(st, keep.session.id, 9000, lim).ok, "and leaves what it has not")

    ' --- CSRF ---
    sess = gdash_session.create(st, "hal", 4000)
    tok = gdash_session.csrf_for("server-secret", sess.session.id)
    s = gdash_test.ok(s, gdash_session.csrf_ok("server-secret", sess.session.id, tok), "a token checks against its own session")
    other = gdash_session.create(st, "hal", 4000)
    s = gdash_test.ok(s, not gdash_session.csrf_ok("server-secret", other.session.id, tok), "and not against another session")
    s = gdash_test.ok(s, not gdash_session.csrf_ok("other-secret", sess.session.id, tok), "nor under another server secret")
    s = gdash_test.ok(s, not gdash_session.csrf_ok("server-secret", sess.session.id, ""), "an empty token never passes")
    s = gdash_test.ok(s, not gdash_session.csrf_ok("server-secret", "", tok), "and neither does an empty session")

    ' --- the cookie ---
    ck = gdash_session.cookie("gdash_session", "abc", false, 3600)
    s = gdash_test.contains_text(s, ck, "HttpOnly", "the cookie is HttpOnly")
    s = gdash_test.contains_text(s, ck, "SameSite=Lax", "and SameSite")
    s = gdash_test.contains_text(s, ck, "Max-Age=3600", "and bounded")
    s = gdash_test.ok(s, not contains(ck, "Secure"), "and NOT Secure over http -- design §6 expects intranet without TLS")
    s = gdash_test.contains_text(s, gdash_session.cookie("gdash_session", "abc", true, 3600), "Secure", "but Secure over https")
    s = gdash_test.contains_text(s, gdash_session.clearing_cookie("gdash_session", false), "Max-Age=0", "logout clears the cookie")

    exit(gdash_test.report(s))
end program
