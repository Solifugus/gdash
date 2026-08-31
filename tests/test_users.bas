' Local accounts. Every password here is obviously fake and every hash is
' computed, never pasted (CLAUDE.md).

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_users from "../src/gdash_users.bas"

    s = gdash_test.suite("users")
    root = args[0]
    p = gdash_paths.roles(root)

    ' --- an absent user file is an empty one, not an error ---
    loaded = gdash_users.load_users(p)
    s = gdash_test.ok(s, loaded.ok, "a server with no user file loads")
    s = gdash_test.eq(s, count(gdash_users.names(loaded.db)), 0, "with no users in it")

    ' ...but nobody can log in, which is the point: no default account, no
    ' bootstrap token, nothing that exists before someone chose it.
    s = gdash_test.ok(s, not gdash_users.authenticate(loaded.db, "admin", "admin").ok, "and no default account works")
    s = gdash_test.ok(s, not gdash_users.authenticate(loaded.db, "", "").ok, "nor an empty one")

    ' --- add and authenticate ---
    db = gdash_users.upsert(gdash_users.empty(), "ada", password_hash("fake-password-for-tests"), ["analysts", "finance"], false, false)
    db = gdash_users.upsert(db, "root_of_all", password_hash("another-fake-one"), [], true, false)
    db = gdash_users.upsert(db, "gone", password_hash("third-fake"), ["analysts"], false, true)

    good = gdash_users.authenticate(db, "ada", "fake-password-for-tests")
    s = gdash_test.ok(s, good.ok, "the right password authenticates")
    s = gdash_test.eq(s, good.user.name, "ada", "yielding the identity")
    s = gdash_test.eq(s, count(good.user.groups), 2, "with its groups")
    s = gdash_test.ok(s, not good.user.admin, "and no admin it was not given")
    s = gdash_test.ok(s, gdash_users.authenticate(db, "root_of_all", "another-fake-one").user.admin, "an admin is an admin")

    ' --- every refusal is the same refusal ---
    wrong = gdash_users.authenticate(db, "ada", "not-it")
    absent = gdash_users.authenticate(db, "nobody", "not-it")
    disabled = gdash_users.authenticate(db, "gone", "third-fake")
    s = gdash_test.ok(s, not wrong.ok, "a wrong password is refused")
    s = gdash_test.ok(s, not absent.ok, "an unknown user is refused")
    s = gdash_test.ok(s, not disabled.ok, "a disabled account is refused even with the right password")
    s = gdash_test.eq(s, wrong.message, absent.message, "a wrong password and an unknown user say exactly the same thing")
    s = gdash_test.eq(s, disabled.message, absent.message, "and so does a disabled account")
    s = gdash_test.ok(s, not contains(wrong.message, "ada"), "and the refusal does not echo the username back")

    ' --- a corrupt hash fails closed ---
    broken = gdash_users.upsert(gdash_users.empty(), "ada", "not-a-hash-at-all", [], false, false)
    s = gdash_test.ok(s, not gdash_users.authenticate(broken, "ada", "anything").ok, "a corrupt hash cannot be authenticated against")

    ' --- one hash field, and it really is per-password salted ---
    h1 = password_hash("same-fake-password")
    h2 = password_hash("same-fake-password")
    s = gdash_test.ok(s, h1 != h2, "two hashes of one password differ")
    s = gdash_test.ok(s, password_verify("same-fake-password", h1) and password_verify("same-fake-password", h2), "and both verify")

    ' --- round trip through the file, at 0600 ---
    s = gdash_test.ok(s, gdash_users.save(p, db), "the user file saves")
    back = gdash_users.load_users(p)
    s = gdash_test.ok(s, back.ok, "and loads")
    s = gdash_test.eq(s, count(gdash_users.names(back.db)), 3, "with every user")
    s = gdash_test.ok(s, gdash_users.authenticate(back.db, "ada", "fake-password-for-tests").ok, "who can still authenticate")

    mode = process.run({ command: "stat", args: ["-c", "%a", gdash_paths.users_file(p)] })
    s = gdash_test.eq(s, trim(mode.stdout), "600", "the user file is 0600 -- the hashes are in it")

    ' --- a user file that cannot be parsed is not a user file with no users ---
    bf {file} = gdash_paths.users_file(p)
    write(bf, "{ corrupted")
    corrupt = gdash_users.load_users(p)
    s = gdash_test.ok(s, not corrupt.ok, "a corrupt user file is an error")
    s = gdash_test.contains_text(s, corrupt.message, "not valid JSON", "and says so")

    ' It must NOT read as "no users": that would be a locked door quietly
    ' removed, and every caller checks ok before it checks the users.
    s = gdash_test.eq(s, count(gdash_users.names(corrupt.db)), 0, "and yields nothing anyone can log in as")

    ' --- changing a password keeps everything else ---
    db2 = gdash_users.upsert(db, "ada", password_hash("rotated-fake"), ["analysts", "finance"], false, false)
    s = gdash_test.ok(s, gdash_users.authenticate(db2, "ada", "rotated-fake").ok, "the new password works")
    s = gdash_test.ok(s, not gdash_users.authenticate(db2, "ada", "fake-password-for-tests").ok, "the old one does not")

    ' An empty hash on upsert means "leave the password alone", which is what
    ' a groups change must not silently reset.
    db3 = gdash_users.upsert(db2, "ada", "", ["analysts"], false, false)
    s = gdash_test.ok(s, gdash_users.authenticate(db3, "ada", "rotated-fake").ok, "changing groups does not reset the password")
    s = gdash_test.eq(s, count(gdash_users.identity(db3, "ada").groups), 1, "but does change the groups")

    ' --- identity ---
    s = gdash_test.eq(s, gdash_users.identity(db, "ada").name, "ada", "identity names the user")
    s = gdash_test.ok(s, is_unknown(gdash_users.identity(db, "nobody")), "an unknown user has no identity")
    s = gdash_test.ok(s, is_unknown(gdash_users.identity(db, "gone")), "and neither does a disabled one")

    ' --- removal ---
    s = gdash_test.eq(s, count(gdash_users.names(gdash_users.drop_user(db, "ada"))), 2, "a user can be removed")
    s = gdash_test.ok(s, is_unknown(gdash_users.lookup(gdash_users.drop_user(db, "ada"), "ada")), "and is then not there")

    exit(gdash_test.report(s))
end program
