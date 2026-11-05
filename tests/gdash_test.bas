' Minimal assertion helpers. A gBASIC function cannot change its caller, so a
' suite is a value that each assertion returns updated -- assign the result.

library gdash_test

    function suite(name)
        return { name: name, passed: 0, failed: 0, failures: [] }
    end function

    ' An `unknown` condition is a failure that says so, not a raise: since
    ' gBASIC's three-valued logic (gbasic 4f3eb1e), an assertion over an absent
    ' value answers unknown, and a suite that dies there reports nothing after it.
    function ok(s, cond, label)
        if is_unknown(cond) then
            return { name: s.name, passed: s.passed, failed: s.failed + 1, failures: concat(s.failures, [label + " -- the condition was unknown"]) }
        end if
        if cond then
            return { name: s.name, passed: s.passed + 1, failed: s.failed, failures: s.failures }
        end if
        return { name: s.name, passed: s.passed, failed: s.failed + 1, failures: concat(s.failures, [label]) }
    end function

    ' "The same value", not the operator: `unknown = unknown` is unknown, and a
    ' test that expects an absence must be able to say so. Compound `=` uses
    ' the deep equality, where unknown is the same value as unknown.
    function eq(s, actual, expected, label)
        if [actual] = [expected] then
            return ok(s, true, label)
        end if
        return ok(s, false, label + " -- expected <" + string(expected) + "> got <" + string(actual) + ">")
    end function

    function contains_text(s, haystack, needle, label)
        if contains(haystack, needle) then
            return ok(s, true, label)
        end if
        return ok(s, false, label + " -- <" + needle + "> not found in <" + haystack + ">")
    end function

    ' Prints the report and returns the process exit code.
    function report(s)
        i = 0
        while i < count(s.failures)
            print("  FAIL: " + s.failures[i])
            i += 1
        end while
        total = s.passed + s.failed
        if s.failed = 0 then
            print("ok   " + s.name + " (" + string(total) + " assertions)")
            return 0
        end if
        print("FAIL " + s.name + " (" + string(s.failed) + "/" + string(total) + " failed)")
        return 1
    end function

end library
