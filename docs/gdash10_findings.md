# GDASH-10 — Findings

**Status:** complete. The chart library's side landed at gbasic `a1f6da5`;
this is what gdash found taking it up.

---

## G10-1 — a scatter lost points, behind the refusal that hid it

Removing gdash's numeric-x refusal exposed a worse bug underneath it.
`_pivot` slots values by unique x and the last row wins, so:

```
four readings, two of them at the same x  ->  three circles
```

Silent, in the one mark whose entire job is drawing every row. It could not be
seen while the refusal stood, because the refusal fired first on exactly the
data that would have shown it.

A scatter now builds its frame one entry per row and never goes through the
pivot at all. For the marks that genuinely need one value per slot, keeping a
row at random **is an aggregation** — design §2 puts aggregation in the SQL —
so `bar`, `line` and `area` refuse a repeated x and name the value, pointing at
`group by`. Two series at one x is not a repeat; that is what a series channel
is for.

**The library and gdash reached the same rule from opposite ends.** The commit
that unblocked this allows a repeated category on a line and refuses it on a
bar, reasoning that a bar would have to invent a sum and a line invents
nothing. gdash's pivot was inventing one silently for all three.

## G10-2 — the repeat detector collided with gdash's own finding

The first version keyed on `x + chr(0) + series`, the usual "a character that
cannot appear in the data" trick. A NUL truncates a record key (G6-16), so
every pair sharing an x collided and every grouped bar broke.

Two levels of record instead of a joined key. Recorded because the lesson is
not about NUL: **any separator is a character that can appear in the data**,
and a nested record needs no separator at all.

## G10-3 — the assertion audit refused two assertions I meant

Asserting `gdashPublish` and `closest('[data-publishes]')` against a fetched
dashboard page: both are in the shim, which is on every page, so both would
pass with the feature removed from that dashboard. The audit flagged them.

They were not accidental — the shim's content is a real thing to assert. But
asserting it by fetching a dashboard is asserting furniture, and the audit
cannot tell a deliberate furniture assertion from a careless one. Rather than
weaken the audit with an allowlist, the assertions moved to
`tests/test_app.bas`, which calls `_shim()` directly — **where the thing is
produced**, which is where it belonged anyway.

The audit stayed strict and the tests got better, which is the argument against
allowlists in one example.

## G10-4 — what the reference dashboard had been showing

`trend_by_region` has been a `line` over a text `month` since GDASH-0. It drew
**nothing** for eight phases, then was refused for one, and now draws. Nobody
noticed because the test asserted `contains(frag, "<svg")` and an empty frame
satisfies it.

Worth stating plainly at the end of this phase: the defect was found by the
platform's author reading gdash's bug report, not by gdash's own suite, which
had a passing assertion pointed straight at it.
