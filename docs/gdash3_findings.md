# GDASH-3 — Findings

Recorded as they were found. Step-0 items are verifications of the phase's
premises and are written up in the brief §1; what follows is what the work
turned up. Platform items are findings for this report and candidates for
gbasic's DOGFOOD.md, filed only through that repo's own process (CLAUDE.md).

Checked against gBASIC `e8b3549`.

---

## G3-1 — the namespace sweep paid for itself on its first new module

`gdash_diff` shipped a function called `lines`. `lines` is a **builtin** — the
line count of a file — and gBASIC said so on the first run:

> `warning: function 'lines' from library 'gdash_diff' has same name as a
> built-in; unqualified calls use the built-in`

followed immediately by `lines expects a file reference`, because the module's
own unqualified calls to it had silently been reaching the builtin all along.

This is F6's third appearance (GDASH-0 F6, GDASH-1 G1-2, here) and the first
one that cost nothing: it surfaced on the first execution, named the collision
and the resolution, and the fix was a rename. The mechanism built in GDASH-2
after I had wrongly reported it as built (G2-8) is now the thing that catches
this class, and `gdash_diff` was in the sweep's probe before it had a test.

Worth recording precisely because nothing went wrong. A hazard that has bitten
three times is not a hazard that will stop biting; what changed is how long it
bites for.

## G3-2 — a published dashboard's manual dataset had no way to be refreshed

GDASH-2's CLI hard-wired `refresh` to the **draft**, on the reasoning that a
person asking is a manual trigger and draft datasets refresh manually only.
That reasoning was half right and the code was wrong.

`manual` is a legal policy for a *published* dataset too — design §3 says
published datasets follow their policy, and `manual` is one. So a published
dashboard whose dataset is `manual` could be refreshed from the browser's
refresh button and by nothing else. No CLI verb reached it, no cron could, and
the scheduler correctly declines to touch a manual dataset. The data would sit
there until someone opened the page and pressed a button.

Found by writing the end-to-end arc for §2.3, not by reading the code: the
test needed to refresh a published manual dataset and there was no way to say
it. **Fixed**: `refresh` now targets what the dashboard *serves* — published
when published, draft otherwise — with `--draft` to force the draft, which is
what an author wants mid-edit.

The general shape is worth keeping: the hole existed because "a person asking"
and "the draft" were conflated into one concept, and they are two. GDASH-2's
own `trigger` parameter had already separated them everywhere except here.

## G3-3 — a definition change and an unchanged result compose oddly, and correctly

Rewriting a dataset's query usually changes the *definition* without changing
the *result* — `where region <> 'nowhere'` over data with no such region
returns exactly the same rows. So the refresh that follows a definition change
routinely takes the GDASH-2 dedupe path: no swap, no version bump, no reload
for anyone.

The state is still written, so the recorded definition advances and the "the
definition changed" warning clears. That is right, and it reads wrong at first
glance — the page said something was wrong, a refresh reported "unchanged",
and the warning went away without anything visibly happening.

Recorded because it is exactly the kind of composition that gets "fixed" later
by someone who reads it as a bug. It is not: the warning is about the record
and its data disagreeing, and after the refresh they agree. The end-to-end run
asserts this path by name so the reasoning is attached to a test.

## G3-4 — `append` mutates in place; `concat` copies

gdash has used `out = concat(out, [x])` since GDASH-0, which allocates a new
array per element. `append(a, x)` mutates in place: 20,000 appends measured at
0.019s, where the `concat` idiom is quadratic.

Nothing built before this phase cared — the arrays are dataset rows and
validation errors, tens of elements at most. `gdash_diff`'s LCS table is the
first place in gdash where the difference is between a small quadratic and a
large one, so that module uses `append` and says why at the top. Everything
else keeps `concat`, because consistency is worth more than an optimisation
nothing needs.

Recorded so that a future reader finding two idioms in one codebase finds the
reason with them rather than assuming drift.

## G3-5 — an empty record has no lines

`gdash_diff.text_lines("")` returns zero lines, not one empty line: a trailing
newline is a terminator rather than a separator, and an empty text has nothing
to terminate. This is a deliberate choice with a test on it, and it is what
makes "publish over an empty file" produce a diff of pure additions rather
than one phantom removal of a line that was never there.

Noted because the alternative is defensible and the difference is invisible
until exactly that case.
