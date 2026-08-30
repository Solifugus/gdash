' The due-decision, against a fabricated clock. Nothing here sleeps: a test
' that waits for an interval to elapse is a test of `sleep` (brief §3).

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_sched from "../src/gdash_sched.bas"
    load gdash_paths from "../src/gdash_paths.bas"

    s = gdash_test.suite("sched")
    root = args[0]

    manual = { refresh: "manual" }
    on_open = { refresh: "on_open" }
    gated = { refresh: "on_open", min_age: 60 }
    every5 = { refresh: "interval", every: 300 }
    fresh = gdash_sched.state_defaults()

    ' A person asking outranks every policy, including a draft's.
    s = gdash_test.ok(s, gdash_sched.due(manual, fresh, 1000, "manual").due, "manual trigger is always due")
    s = gdash_test.ok(s, gdash_sched.due(every5, fresh, 1000, "manual").due, "manual trigger beats an unelapsed interval")

    ' manual policy never fires on a tick.
    d = gdash_sched.due(manual, fresh, 1000, "policy")
    s = gdash_test.ok(s, not d.due, "manual policy is never due on a tick")
    s = gdash_test.eq(s, d.reason, "policy is manual", "and says why")

    ' A record with no refresh key at all is manual.
    s = gdash_test.eq(s, gdash_sched.policy_of({ profile: "w" }), "manual", "absent refresh means manual")

    ' interval: never refreshed is due immediately.
    d = gdash_sched.due(every5, fresh, 1000, "policy")
    s = gdash_test.ok(s, d.due, "interval never refreshed is due")
    s = gdash_test.eq(s, d.reason, "never refreshed", "and says why")

    ' interval boundaries, exactly.
    at700 = gdash_sched.after_attempt(fresh, 700, true, "", 10, "h")
    s = gdash_test.ok(s, not gdash_sched.due(every5, at700, 999, "policy").due, "one second before the interval: not due")
    s = gdash_test.ok(s, gdash_sched.due(every5, at700, 1000, "policy").due, "exactly at the interval: due")
    s = gdash_test.ok(s, gdash_sched.due(every5, at700, 1001, "policy").due, "past the interval: due")
    s = gdash_test.eq(s, gdash_sched.due(every5, at700, 999, "policy").reason, "next in 1s", "the wait is reported")

    ' A failed attempt counts as an attempt, so a dead source is retried on
    ' its own cadence and not at the scheduler's tick rate.
    failed = gdash_sched.after_attempt(at700, 900, false, "source refused", 0, "")
    s = gdash_test.ok(s, not gdash_sched.due(every5, failed, 1000, "policy").due, "a failure does not make the next tick due")
    s = gdash_test.ok(s, gdash_sched.due(every5, failed, 1200, "policy").due, "a failure retries one interval later")
    s = gdash_test.eq(s, failed.last_error, "source refused", "the failure is remembered")
    s = gdash_test.eq(s, failed.last_success, 700, "a failure does not move last_success")
    s = gdash_test.eq(s, failed.rows, 10, "a failure does not discard the row count of the data still being served")

    ' on_open: nothing happens until someone opens it.
    s = gdash_test.ok(s, not gdash_sched.due(on_open, fresh, 1000, "policy").due, "on_open with no request is not due")
    asked = gdash_sched.with_request(fresh, 1000)
    s = gdash_test.ok(s, gdash_sched.due(on_open, asked, 1000, "policy").due, "on_open with a request is due")

    ' The request is a flag, not a queue.
    s = gdash_test.ok(s, gdash_sched.should_request(on_open, fresh, 1000), "a first open requests")
    s = gdash_test.ok(s, not gdash_sched.should_request(on_open, asked, 1000), "a second open does not request again")
    s = gdash_test.ok(s, not gdash_sched.should_request(manual, fresh, 1000), "a manual dataset never requests")
    s = gdash_test.ok(s, not gdash_sched.should_request(every5, fresh, 1000), "an interval dataset never requests")

    ' min_age suppresses the request while the data is young.
    young = gdash_sched.after_attempt(fresh, 980, true, "", 3, "h")
    s = gdash_test.ok(s, not gdash_sched.should_request(gated, young, 1000), "min_age suppresses a request on young data")
    s = gdash_test.ok(s, gdash_sched.should_request(gated, young, 1040), "min_age lets the request through once the data ages")

    ' A completed attempt clears the request, so it is not retried forever.
    served = gdash_sched.after_attempt(asked, 1010, true, "", 5, "abc")
    s = gdash_test.eq(s, served.requested, 0, "success clears the pending request")
    failed2 = gdash_sched.after_attempt(asked, 1010, false, "down", 0, "")
    s = gdash_test.eq(s, failed2.requested, 0, "failure clears the pending request too")

    ' An unknown policy refuses to guess.
    s = gdash_test.ok(s, not gdash_sched.due({ refresh: "hourly" }, fresh, 1000, "policy").due, "an unknown policy is never due")

    ' State survives a round trip through the file, and a missing file reads
    ' as a dataset that has never refreshed.
    made = gdash_paths.ensure_dir(root)
    path = root + "/orders.state.json"
    s = gdash_test.eq(s, gdash_sched.read_state(path).last_success, 0, "missing state reads as never refreshed")
    s = gdash_test.ok(s, gdash_sched.write_state(path, served), "state writes")
    back = gdash_sched.read_state(path)
    s = gdash_test.eq(s, back.last_success, 1010, "last_success round trips")
    s = gdash_test.eq(s, back.hash, "abc", "hash round trips")
    s = gdash_test.eq(s, back.rows, 5, "rows round trip")

    ' A corrupt state file is a dataset we know nothing about, not a crash.
    bf {file} = path
    write(bf, "{not json")
    s = gdash_test.eq(s, gdash_sched.read_state(path).last_success, 0, "corrupt state reads as never refreshed")

    exit(gdash_test.report(s))
end program
