' A scripted model, for the NLQ pipeline's hermetic tests.
'
' gdash ships one implementation of the seam: gdash_ask.live_model, one thin
' wrapper over stdlib `llm`. This is the other one. It speaks the same single
' function and answers from a plan held in its ctx.
'
' It exists because a REAL model cannot be made to return the same wrong thing
' twice, and the wrong things are most of what the pipeline handles: prose
' instead of SQL, a DELETE, a query naming a table the grounding does not have,
' valid SQL that does not compile, and a comparison against cents that is
' plausible and wrong. Every one of those is a branch, and none of them can be
' tested by asking a good model nicely.
'
' plan = {
'   reply:  "<text the model returns>",
'   fail:   ""  or a reason string    -- the transport half of the seam
'   log:    <path>  -- the system and user prompts, so a test can assert what
'                      gdash actually told the model rather than what it meant to
'   usage:  { input, output }  -- tokens the call reports, for the budget
'   price:  { currency, input, output }  -- as a model profile states it
' }
'
' gBASIC has function references and not closures, so the plan travels as ctx,
' and call accounting goes to a file for the same reason a library cannot hold
' mutable state.

library model_double

    function complete(ctx, system, user)
        path = string(default(ctx["log"], ""))
        if path != "" then
            on error goto next
            f {file} = path
            prior = ""
            if exists(f) then
                prior = read(f)
            end if
            write(f, prior + "--- system ---" + chr(10) + system + chr(10) + "--- user ---" + chr(10) + user + chr(10))
        end if
        reason = string(default(ctx["fail"], ""))
        if reason != "" then
            return { ok: false, text: "", reason: reason }
        end if
        ' `usage` is what a provider would report, for the budget's meter
        ' (GDASH-16); a plan that sets none reports none, as a local model does.
        return { ok: true, text: string(default(ctx["reply"], "")), reason: "", usage: ctx["usage"] }
    end function

    function saying(reply)
        return { ctx: { reply: reply }, complete: model_double.complete }
    end function

    function saying_into(reply, logpath)
        return { ctx: { reply: reply, log: logpath }, complete: model_double.complete }
    end function

    function failing(reason)
        return { ctx: { fail: reason }, complete: model_double.complete }
    end function

    ' What the model was told, as one string. The prompt is the thing gdash is
    ' actually responsible for.
    function prompted(path)
        on error goto next
        f {file} = path
        if not exists(f) then
            return ""
        end if
        txt = read(f)
        if error then
            return ""
        end if
        return txt
    end function

end library
