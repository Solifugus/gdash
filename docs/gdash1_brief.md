# GDASH-1 — Record format completion: phase brief

**Status:** COMPLETE. All six §5 criteria met; at the review boundary.
Findings in `gdash1_findings.md`; DONE note in §7.
**Narrows:** the GDASH-1 paragraph of `gdash_development_plan.md`.
**Authority:** `gdash_design.md` outranks this brief. GDASH-0's findings
(`gdash0_findings.md`) are inputs, not open questions.

GDASH-0 proved the spine on one dataset, one param, two marks and one tab.
GDASH-1 makes the record format mean what it promises. It adds no new spine:
every station GDASH-0 built stays, and this phase widens what flows through it.

---

## 1. Step-0 verification

Two premises decide this phase's shape. Both checked against gBASIC `7ae5c1b`.

- **`sqlite.columns` — STILL ABSENT.** `invalid function call: sqlite.columns`.
  The plan says to decide here: since the platform item has not landed, this
  phase **pins the first-refresh fallback** as the ruling behaviour rather than
  waiting. Channel validation stays where GDASH-0 put it — against a real
  result set — and gains golden refusal messages like every other check.
  Load-time red/green remains *partial*, and the format doc says so plainly
  rather than implying a completeness the platform cannot yet support.
- **The money type is now usable — VERIFIED.** Authored text stops at the
  storage scale (`exponent + 4`: USD 6, KWD 7, JPY 4), retention through
  arithmetic is real (`0.10432 * 1000` → `104.32`, exact), and
  `money.text(m [, places])` reads a value back exactly and round-trips. So
  the consolidation GDASH-0 deferred is unblocked, and the `currency` format
  in §3.4 delegates to the platform instead of hand-rolling string surgery.

## 2. Scope — the narrowing

### 2.1 Marks

`bar`, `value` (both from GDASH-0), plus **`line`** and **`table`**.

- **`series`** channel on `bar` and `line`: one result column names the series,
  and rows fan out into multiple series in result order. Colours come from a
  fixed categorical palette (design §2); no per-series override — that is
  named in design §10 as the first styling knob to add *later*.
- **`table`** is the deliberate odd one out (design §2): it renders result
  columns **in SELECT order** with a per-column `formats` map. It does not
  take `x`/`y`/`series`. The SQL stays the single place shape is decided, so
  `table` gets no column list, no ordering options, and no aggregation.

Not built: every other mark. `area`, `pie`, `scatter` and the rest wait for
GDASH-6 and real dashboards to ask.

### 2.2 Layout

Full `space` / `gap` / `weight` semantics per design §2:

- `weight` flexes a child; a child without one takes natural size.
- `space` (`between` / `around` / `evenly` / `start` / `end` / `center`)
  governs leftover room.
- **The dead-`space` warning**: `space` is ignored, *with a validation
  warning*, when every child is weighted — because then there is no leftover
  room for it to govern. This is the phase's first **warning** as distinct
  from an error: it does not refuse the record.
- `gap` sets inter-child spacing.

### 2.3 Tabs

`tabs[]` with more than one entry, each a named layout tree. All tabs render
server-side in one response and switch client-side, because workers share no
in-memory state (design §5) and a tab switch must not need a round trip to
re-establish which tab a viewer is on. Params are shared across tabs: a slicer
on one tab moves the visuals that bind it wherever they live.

### 2.4 The format map

`formats` maps a result column to a format name. **`currency` is required**;
this phase also ships `number` and `percent`, which is what a table of business
figures needs to be readable at all.

- **`currency` delegates to the platform money type.** A minor-unit integer
  becomes a money value through `money.text`-shaped exact text, never through
  a double, and renders at the currency's own precision. GDASH-0's
  `from_minor`/`format_currency` string surgery is replaced, not kept beside
  it — two implementations of money formatting is exactly the duplication the
  consolidation exists to end.
- The dataset's declared currency drives it. A money column gains an optional
  `currency` key (default `USD`), so JPY and KWD columns render at their own
  exponents rather than assuming cents.
- `number` takes optional `decimals`; `percent` renders a ratio.

Deferred by name: date/time formats, locale-aware grouping, per-format
options beyond `decimals`.

### 2.5 The validation catalog, with goldens

Every refusal this build can emit is enumerated and its **exact message text
pinned as a golden**. GDASH-0 asserted only that the right condition was
caught, deliberately, so this phase could fix the wording without rewriting
assertions. That debt is paid here.

- One golden file holds every message; a test drives each refusing record and
  compares byte-for-byte.
- Warnings are pinned the same way and kept distinct from errors: a record
  with warnings still loads.
- The catalog is the format doc's error appendix, generated from the same
  source as the goldens so the two cannot drift.

### 2.6 The record format, versioned for real

`docs/gdash_record_format.md`: every key, its meaning, whether it is required,
and what refuses it — `format: 1`, stated as a stable contract rather than a
description of current code. The reference record grows to exercise everything
this phase adds (multiple tabs, all four marks, series, a formats map, the
layout knobs) and remains the thing the suite renders.

## 3. Construction rules

Unchanged from GDASH-0 §4, and additionally:

- **No new modules without a reason.** Marks live in `gdash_render`; formats
  get `gdash_format` only because the format map is consulted by both the
  `table` mark and the scalar marks, and burying it in either would make the
  other depend on it sideways.
- **The money boundary still holds.** Values that can exceed 2^53 minor units
  cross as text (F1). Delegating to the money type does not change that: the
  text goes to `{CUR}=` directly, and no `number()` appears on the path.
- **GDASH-0's findings are not re-litigated.** F3 (`load` per block), F6
  (no library namespace — check every new public name against the stdlib
  before using it) and F8 apply as written.

## 4. Tests

Tests first, hermetic, scratch-clean, as GDASH-0. Additionally:

- **Goldens for every refusal and every warning**, byte-for-byte.
- **A retention test for currency formatting**, following the platform
  session's own warning: display alone cannot distinguish an exactly-stored
  sub-minor-unit value from one rounded at the door, because both render the
  same. Only arithmetic separates them, so the assertion multiplies before
  formatting.
- **A layout test per `space` value**, and one that asserts the dead-`space`
  warning fires when every child is weighted and *not* when one is not.
- **A `series` test** asserting one query fans out to the right number of
  series, and a `table` test asserting SELECT order is preserved exactly.
- The end-to-end run grows a tab switch and a table render.

## 5. Done means

1. The reference record exercises all four marks, series, multiple tabs, the
   layout knobs and the format map, and renders.
2. Every refusal and warning matches its golden.
3. `currency` formatting goes through the platform money type, with GDASH-0's
   string surgery removed rather than left beside it.
4. `docs/gdash_record_format.md` documents `format: 1` completely, including
   what load-time validation still cannot check and why.
5. The hermetic suite and the live-Postgres runner both pass.
6. Findings recorded; DONE note names everything deliberately not built.

## 6. Deliberately not built

Refresh policies beyond `manual` and multi-dataset ATTACH (GDASH-2);
draft/publish/snapshots (GDASH-3); auth, sessions, `user_*` (GDASH-4/5); marks
beyond the four; per-series colour override and theming (GDASH-6); legends and
axis formatting beyond what the chart library already gives; date formats;
locale grouping; systemd and FHS install (GDASH-7).

Load-time channel validation remains impossible until `sqlite.columns` ships;
the first-refresh fallback is pinned here as the ruling behaviour.


---

## 7. DONE note

All six §5 criteria met. The hermetic suite is 12 suites — 222 in-process
assertions plus 31 end-to-end — green from a clean checkout with no services
running, ending scratch-clean; the opt-in live-Postgres runner passes 5/5.

**Built:** the format map (`currency` delegating to the platform money type,
plus `number`, `percent`, `text`); the `line` and `table` marks; the `series`
channel on `bar` and `line`; full `space`/`gap`/`weight` semantics with the
dead-`space` warning; multiple tabs rendered server-side and switched on the
client; the validation catalog pinned as 45 golden cases; and
`docs/gdash_record_format.md` documenting `format: 1` with its refusal
appendix generated from the golden.

**Removed, not kept beside:** `gdash_store.from_minor` and
`gdash_render.format_currency`. Two implementations of money formatting was
the duplication the consolidation existed to end.

**Deliberately not built** — §6 stands, with these to record:

- **Currency support is eight codes**, not all 178 the platform now carries.
  `load` takes a compile-time literal and the currency modifier is a literal
  too, so each supported code is an explicit branch. Widening it is mechanical;
  doing it for 178 codes wants generation rather than typing, which is not this
  phase's business.
- **Format options stop at `decimals`.** No locale grouping, no date or time
  formats, no per-format alignment. `currency`, `number`, `percent` and `text`
  are what a business table needs to be readable.
- **`series` colours come from the chart library's categorical palette.**
  Per-series override is named in design §10 as the first styling knob to add
  later, and it is still later.
- **A table paginates nothing.** A visual query returning ten thousand rows
  renders ten thousand rows. Downsampling is SQL's job (design §5); a row cap
  belongs with the theme and table options GDASH-6 will want.
- **Tab state is not addressable.** Reloading returns to the first tab; there
  is no `#tab=2`. Session pinning of any kind belongs to GDASH-3.

**Design edits still owed** (unchanged, both the maintainer's): §4's money
headroom figure, and §4's stated render path — now more precisely, that
formatting goes through the money type but is bounded by its storage scale.
