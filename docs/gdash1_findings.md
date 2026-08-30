# GDASH-1 — Findings

**Status:** phase complete; at the review boundary.
**Platform:** gBASIC `7ae5c1b` (0.1.0-rc9 money work).
Everything here was probed against the real binary.

---

## G1-1 — Delegating to the money type narrows gdash's renderable range

**Severity: medium; a deliberate ruling, recorded because it is a real
trade.**

GDASH-0's F5 asked the platform for an exact money constructor so gdash's
hand-rolled formatting could delegate. It shipped, and gdash now delegates —
`gdash_store.from_minor` and `gdash_render.format_currency` are deleted rather
than kept beside the new path.

The trade is range. Guard digits make money an int64 at `exponent + 4`, so USD
caps at **$9,223,372,036,854.77**, while gdash's own SQLite storage still holds
int64 minor units at the declared scale (±$92 quadrillion at scale 2). Above
the cap, gdash **refuses to render**, saying the data is intact and only
rendering declines.

The alternative — falling back to string formatting above a threshold — was
rejected: it would put two rounding semantics in one column, switching
invisibly at a magnitude no reader could predict. A clear refusal is better
than a silent second path.

**A correction owed to the platform session.** When they warned "if gdash holds
anything near the old ceiling, check it," I answered that gdash held nothing
near it. That was wrong: GDASH-0's own F1 exactness test used 2^53 minor units
(~$90 trillion), which is above the new USD ceiling. The test now asserts
exactness just under the real ceiling and asserts the refusal above it. The
lesson is the ordinary one — I answered a range question from memory of the
design rather than from the tests.

## G1-2 — F6 recurred, inside gdash, within a day of being reported

**Severity: medium; the tax is ongoing, not a one-off.**

`gdash_format._digits_only` silently overrode `gdash_store._digits_only`. Same
class as GDASH-0's F6 (`web.resolve`, `chart._escape`), but this time between
two of gdash's own modules, in a phase whose brief explicitly said to check
every new name against the stdlib first. Underscore-prefixed helpers are not
private, and a warning on stderr is easy to miss in a passing test run.

The suite now **sweeps every module for override warnings** rather than relying
on someone reading them. That is a workaround for a platform property, not a
fix; the platform ask (make the override an error, or scope definitions to
their library) stands as filed.

## G1-3 — `sqlite.columns` is still absent, so the fallback is now the ruling

The plan told GDASH-1 to decide this. The platform item has not shipped, so
**the first-refresh fallback is pinned as the ruling behaviour**, not as a
holding position: channel validation happens against a real result set when a
visual first renders, and shows in that visual's cell.

`docs/gdash_record_format.md` §6 states plainly that load-time red/green is
partial and why, rather than implying a completeness the platform cannot yet
support. If `sqlite.columns` ships later, moving the check earlier is additive.

## G1-4 — `weight` was validated only on containers

**Severity: low; caught by its own test, recorded because of what it says
about where the bug was.**

`weight` is a property of a *child*, and the common case is a weighted leaf.
The first implementation checked it only in the container branch, so
`{"visual": "v1", "weight": 0}` passed validation and reached the CSS. The
layout test caught it immediately.

Worth recording because the mistake was structural rather than careless: the
check was written where the *other* container properties (`space`, `gap`) live,
and those genuinely are container properties. `weight` reads like one and is
not.

## Platform notes (verified, none defects)

- **`chart.line` / `chart.bar` accept a frame record and a list of y columns**,
  which is what makes the `series` channel a pivot rather than a special case.
  `unknown` in a series column renders as a **gap**, so a missing `(x, series)`
  pair needs no sentinel — filling it with zero would be a claim the data never
  made.
- **`keys()` preserves SELECT order** on a `sqlite.query` result record, which
  is what lets the `table` mark render columns in SELECT order without a
  column list. Verified before relying on it.
- **The money fix verifies exactly as described.** Authored text stops at
  `exponent + 4` in every currency tested (USD 6, KWD 7, JPY 4);
  `money.text` round-trips; retention is real. The platform session's warning
  that *display cannot distinguish retention from rounding at the door* is
  correct and shaped the test: the assertion multiplies before formatting
  (`0.10432 * 1000 = 104.32`), because both binaries render `0.10`.

## What this means for the phase after

Nothing here blocks GDASH-2. G1-3 is the only one that changes a plan
assumption, and it changes it in the direction the plan already anticipated.
G1-2 is the standing hazard: every new module is one common noun from a silent
collision, and the sweep catches it only because someone thought to add the
sweep.
