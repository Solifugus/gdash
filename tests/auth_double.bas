' A third provider, for the seam's tests.
'
' gdash ships two: local accounts over users.json, and LDAP over a directory.
' This one answers from a table held in its own ctx. The shape is deliberately
' neither of the shipped ones -- no file, no socket, and an `available` flag
' the test can flip -- because a seam proved against a near-copy of one of its
' implementations is not proved at all. That is the lesson store_double taught
' the session store in GDASH-4.
'
' ctx = { name, up, people: { <username>: { password, email, groups, admin, disabled } } }
'
' gBASIC has function references and not closures, so the table travels as an
' argument rather than being captured.

library auth_double

    load gdash_auth from "../src/gdash_auth.bas"

    function verify(ctx, username, password)
        if not ctx.up then
            return gdash_auth.unreachable("the double is down")
        end if
        who = ctx.people[username]
        if is_unknown(who) then
            return gdash_auth.miss()
        end if
        if who["disabled"] = true then
            return gdash_auth.reject()
        end if
        if string(who["password"]) != password then
            return gdash_auth.reject()
        end if
        return gdash_auth.accept(gdash_auth.make_identity(username, who["email"], who["groups"], who["admin"] = true))
    end function

    function whois(ctx, username)
        if not ctx.up then
            return gdash_auth.unreachable("the double is down")
        end if
        who = ctx.people[username]
        if is_unknown(who) then
            return gdash_auth.miss()
        end if
        if who["disabled"] = true then
            return gdash_auth.reject()
        end if
        return gdash_auth.accept(gdash_auth.make_identity(username, who["email"], who["groups"], who["admin"] = true))
    end function

    function provider(ctx, every)
        return { kind: "double", name: ctx.name, ctx: ctx,
                 authenticate: auth_double.verify,
                 identity: auth_double.whois,
                 revalidate: every }
    end function

end library
