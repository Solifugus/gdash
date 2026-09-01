# Cross-repo ask — the override warning after the resolution fix

**Raised by:** gdash, verifying `d08409f`.
**Ruled by:** the gbasic repo, through its own process.
**Severity:** cosmetic in behaviour, misleading in documentation. Nothing in
gdash is blocked or wrong because of it.

The resolution fix works and gdash is green on it with no changes (G4-12). Two
things about the *warning* did not follow the fix, and one open question about
scope.

---

## Prompt to send to the gBASIC session

> `d08409f` (a library calls its own function first) is verified from gdash's
> side and it fixes F6 at the root. The original scenario — a library defining
> `resolve` loaded alongside a `server` block, which broke every working route
> in GDASH-0 while trivial ones still answered — now dispatches correctly, and
> the shadowing library's own `resolve` is still reachable through its prefix.
> The cross-library fallback survives: a library calling another library's
> function by a bare name it never declared still resolves. gdash's whole suite
> passes on it unchanged — 19 suites, 476 in-process assertions plus 128
> end-to-end, live Postgres 8/8. Five findings across four phases (F6, G1-2,
> G2-8, G4-6, G4-9) turn out to have been one hazard, and it is gone.
>
> Three things about the *warning*, none of which block anything.
>
> **1. The message now describes the opposite of what happens.** The fix
> reached the built-in case too, and the text did not follow it:
>
> ```basic
> library blib
>     function lines(text)                  ' `lines` is a built-in
>         return split(string(text), chr(10))
>     end function
>     function count_them(text)
>         return count(lines(text))         ' bare call, from inside blib
>     end function
> end library
> ```
>
> ```
> warning: function 'lines' from library 'blib' has same name as a built-in;
>          unqualified calls use the built-in     at ./blib.bas:2:5
>
> blib.count_them("a\nb")  ->  2             ' its OWN function won
> lines("a\nb")            ->  raises        ' outside blib, the built-in wins
> ```
>
> So the sentence is true of a call site outside the library and false of the
> one the warning points at. Whichever way you rule the behaviour, the text
> wants to say which side of the boundary it is talking about.
>
> **2. Was the built-in half intended?** The library-vs-library change is
> unambiguously right. Extending it to built-ins is a larger behavioural
> change, and I cannot tell from outside whether it was the point or a
> consequence. Both are defensible: a library author writing
> `function lines(text)` and then calling `lines(x)` plainly means their own,
> so the new behaviour is arguably the better one; but it also means a library
> can now shadow a built-in for itself, which is worth being deliberate about.
> If it was intended, the warning is probably now an informational note rather
> than a warning. If it was not, the scope question is yours.
>
> **3. The warning's line number counts only non-comment lines.** Verified in
> two files:
>
> ```
> blib.bas   — `function lines` on physical line 4, 2 comment lines before it
>              → reported as ./blib.bas:2:5
> blib2.bas  — `function lines` on physical line 7, 5 comment lines before it
>              → reported as ./blib2.bas:2:5
> ```
>
> Both are (physical line − preceding comment lines). Column 5 is correct in
> both. **Ordinary diagnostics are not affected** — a runtime error on physical
> line 6 of a file with three preceding comment lines reports line 6 correctly
> — so this looks specific to this warning's location rather than to the
> diagnostic path generally. In a heavily commented file the pointer lands far
> from the definition; gdash's modules run 20+ comment lines before the first
> function, so in practice it points into the header.
>
> Filing all three together because they are one line of code's worth of
> context, and because a warning that is stale *and* mislocated is worse than
> no warning: it sends a reader to the wrong line to read the wrong claim.
