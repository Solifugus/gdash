' gdash — what a root spends on models (GDASH-16; gdash_saas_design.md §7).
'
' A question costs real money, and in a multi-tenant deployment a tenant
' spends it. This is the meter and the budget's refusal. "The one most likely
' to be discovered by a bill rather than by a test", so it is tested.
'
' THE PRICE IS THE OPERATOR'S, in the model profile, per million tokens:
'
'   "price": { "currency": "USD", "input": "3.00", "output": "15.00" }
'
' as decimal text, read exactly as money. A profile with no price cannot be
' metered, and under a budget that is a refusal rather than an assumption of
' zero.
'
' THE LEDGER is one file a month in the root's state directory, because it is
' a record of money and must survive a reboot. A month is the UTC calendar
' month; a budget is per month.
'
' CHECK, THEN CHARGE. A question is refused when the month's spend has
' reached the budget, and charged afterwards with what it cost. Two questions
' asked at once can both pass the check, so a month can end above its budget
' by at most one question per worker. Reserving the worst case first would
' remove that, and would refuse a question that would have fitted.

library gdash_spend

    load gdash_paths from "gdash_paths.bas"

    function month_of(t)
        d {datetime}= t
        mm = string(d.month)
        if len(mm) < 2 then
            mm = "0" + mm
        end if
        return string(d.year) + "-" + mm
    end function

    function this_month()
        return month_of(now())
    end function

    ' { ok, currency, input, output, message }: money per million tokens.
    function price_of(profile)
        pr = profile["price"]
        if type(pr) != "record" then
            return { ok: false, currency: "", input: unknown, output: unknown, message: "states no price" }
        end if
        code = string(default(pr["currency"], ""))
        on error goto next
        i = money.of(code, string(default(pr["input"], "")))
        o = money.of(code, string(default(pr["output"], "")))
        if error then
            return { ok: false, currency: code, input: unknown, output: unknown, message: "has a price that is not decimal text in a known currency: " + error.message }
        end if
        on error stop
        return { ok: true, currency: code, input: i, output: o, message: "" }
    end function

    ' The month's ledger. Zero when nothing has been spent.
    function read_ledger(p, month, currency)
        empty = { currency: currency, spent: money.of(currency, "0"), calls: 0, estimated: 0, input_tokens: 0, output_tokens: 0 }
        path = gdash_paths.spend_file(p, month)
        if not gdash_paths.path_exists(path) then
            return empty
        end if
        on error goto next
        f {file} = path
        got = try_decode(read(f))
        if error or not got.ok or type(got.value) != "record" then
            ' A ledger that does not read is not a ledger showing nothing
            ' spent. Report it as at no less than the budget, by the caller's
            ' reading of `unreadable`.
            return { currency: currency, spent: unknown, calls: 0, estimated: 0, input_tokens: 0, output_tokens: 0, unreadable: true }
        end if
        on error stop
        v = got.value
        cur = string(default(v["currency"], currency))
        on error goto next
        amt = money.of(cur, string(default(v["spent"], "0")))
        if error then
            return { currency: currency, spent: unknown, calls: 0, estimated: 0, input_tokens: 0, output_tokens: 0, unreadable: true }
        end if
        on error stop
        return { currency: cur, spent: amt, calls: default(v["calls"], 0), estimated: default(v["estimated"], 0),
                 input_tokens: default(v["input_tokens"], 0), output_tokens: default(v["output_tokens"], 0) }
    end function

    ' { ok, message }. `lim` is gdash_limits.for_root(p); `profile` the model
    ' profile the question would use.
    function check_budget(p, lim, profile)
        b = lim.model_budget
        if b = "none" then
            return { ok: true, message: "" }
        end if
        budget = money.of(string(b["currency"]), string(b["amount"]))
        if budget <= money.of(string(b["currency"]), "0") then
            return { ok: false, message: "this site has no model budget, so questions are turned off; the operator sets one with `gdash tenant limit <id> model_budget 25.00USD`" }
        end if
        pr = price_of(profile)
        if not pr.ok then
            return { ok: false, message: "the model profile " + pr.message + ", so what a question costs cannot be counted against this site's budget" }
        end if
        if pr.currency != string(b["currency"]) then
            return { ok: false, message: "the model is priced in " + pr.currency + " and this site's budget is in " + string(b["currency"]) + "; there is no exchange rate here to compare them" }
        end if
        led = read_ledger(p, this_month(), pr.currency)
        if default(led["unreadable"], false) then
            return { ok: false, message: "this month's spend record cannot be read, so it cannot be shown to be under budget" }
        end if
        if led.spent >= budget then
            return { ok: false, message: "this site has spent its model budget for " + this_month() + " (" + money.text(led.spent, 2) + " of " + money.text(budget, 2) + " " + pr.currency + "); questions resume next month or when the operator raises it" }
        end if
        return { ok: true, message: "" }
    end function

    ' What a call cost, from what the provider reported. When it reported
    ' nothing -- a local model, an offline fixture, a provider that changed
    ' shape -- the cost is ESTIMATED HIGH: input at one token per two
    ' characters, output at the profile's max_tokens. An under-count is the
    ' failure a budget exists to prevent.
    function cost_of(profile, usage, prompt_chars)
        pr = price_of(profile)
        it = unknown
        ot = unknown
        if type(usage) = "record" then
            it = usage["input"]
            ot = usage["output"]
        end if
        estimated = false
        if type(it) != "number" then
            it = ceil(prompt_chars / 2)
            estimated = true
        end if
        if type(ot) != "number" then
            ot = number(default(profile["max_tokens"], 4096))
            estimated = true
        end if
        if not pr.ok then
            return { priced: false, cost: unknown, currency: "", input_tokens: it, output_tokens: ot, estimated: estimated }
        end if
        c = pr.input * it / 1000000 + pr.output * ot / 1000000
        return { priced: true, cost: c, currency: pr.currency, input_tokens: it, output_tokens: ot, estimated: estimated }
    end function

    ' Adds one call to the month's ledger, under a lock so two workers'
    ' charges are never one lost. Returns the cost record.
    function charge(p, profile, usage, prompt_chars)
        c = cost_of(profile, usage, prompt_chars)
        month = this_month()
        path = gdash_paths.spend_file(p, month)
        made = gdash_paths.ensure_dir(gdash_paths.dir_of(path))
        on error goto next
        lf {file} = path + ".lock"
        if not exists(lf) then
            write(lf, "")
        end if
        if error then
            return c
        end if
        on error stop
        with lock(lf)
            cur = c.currency
            if cur = "" then
                cur = "USD"
            end if
            led = read_ledger(p, month, cur)
            if not default(led["unreadable"], false) then
                spent = led.spent
                if c.priced and led.currency = c.currency then
                    spent = spent + c.cost
                end if
                est = led.estimated
                if c.estimated then
                    est += 1
                end if
                out = { currency: led.currency, spent: money.text(spent), calls: led.calls + 1, estimated: est,
                        input_tokens: led.input_tokens + c.input_tokens, output_tokens: led.output_tokens + c.output_tokens }
                on error goto next
                tf {file} = path + ".tmp"
                write(tf, encode(out))
                atomic_replace(path + ".tmp", path)
                if error then
                end if
                on error stop
            end if
        end with
        return c
    end function

end library
