# Platform ask — money type (for the gbasic repo)

Raised by GDASH-0 (`gdash0_findings.md` F5). gdash does not need this to work;
it is the consolidation ask. Filing and ruling belong to the gbasic repo's own
process — this file is the record of what gdash asked for and why.

The prompt handed to the gBASIC process follows verbatim.

---

gBASIC's `money` type needs work, and gdash (the sibling repo, first real
consumer of it) has the evidence. Please treat this as a DOGFOOD finding plus
a design change to rule on before implementing — I am not asking you to jump
straight to code.

## What is already right

`money` is an exact int64 scaled integer, which is the correct representation:

```c
static Value value_money(long long cents) { ... }          /* src/eval.c */
static char *odbc_money_text(long long cents)              /* "Money is integer cents" */
```

Verified, not assumed: `0.01` accumulated 1000 times yields exactly `10.00`,
which a double cannot do, and printing a 16-significant-digit value renders it
in full. The storage is not the problem.

## Three defects around that core

1. **Construction launders through a double, and there is no exact way in.**
   A literal or a `number()` result is a `double` before `value_money` ever
   sees it, so `big{USD}= 92233720368547.75` yields `...76` — a cent out. And
   the modifier refuses text: `b{USD}= "92233720368547.75"` raises
   `USD modifier expects a number`. **The type's own int64 range is
   unreachable through its own constructor.**

2. **`*` and `/` by a number leave integer arithmetic.** Both route through
   `round_to_cents(amount / 100.0)` on a `double`. A money value that *was*
   exact is silently degraded the first time it is scaled. This is the worst
   of the three: it corrupts a value the caller had already got right, with no
   error and no warning.

3. **Scale is hardcoded to cents.** There is no per-currency exponent, so JPY
   (0 decimals) has no correct representation, and neither does anything
   needing sub-cent precision.

## The design change being asked for

**Money must carry four guard digits below the currency's minor unit.** For
USD, 3 cents is `3.0000` cents — stored at `scale = currency_exponent + 4`.

This is the requirement financial calculation actually has: interest,
allocations, unit costs and FX conversions all produce intermediate values
below the minor unit, and rounding each one to cents as it is produced loses
money across a multi-step calculation. Four guard digits is the common
convention for exactly this.

Consequences to work through as part of the ruling:

- **Range.** int64 at scale 6 (USD) is ±$9,223,372,036,854.77 — about
  $9.2 trillion. At scale 4 (JPY, exponent 0) it is about ¥922 trillion. Both
  are comfortably beyond real use, but the per-currency range should be stated
  in the reference rather than left to be discovered.
- **Display stays at currency precision.** A USD value still shows two
  decimals by default. The rounding rule used to get there must be chosen and
  documented explicitly (half-even vs half-up — half-even is the usual choice
  for financial reporting); it must not be left implicit.
- **Arithmetic.** `+` and `-` stay exact integer. `*` by an integral scalar
  should stay exact. `/` genuinely needs a rounding rule at storage scale —
  define it, document it, and apply it at the guard-digit scale rather than
  at the minor unit, which is the entire point of the guard digits.
- **Construction from decimal text**, parsed by integer arithmetic with no
  double anywhere on the path. Digits beyond the storage scale should be
  **rejected rather than rounded** — gdash requires this and design §4 of
  gdash's own design doc says excess decimals are rejected, not rounded, so
  please confirm that as the platform ruling too rather than diverging.
- **Compatibility.** `money` is serializable (`serialize`/`deserialize`) and
  `odbc_money_text(long long cents)` assumes cents. A representation change
  touches both, so it needs a versioning or migration decision, not a silent
  reinterpretation of existing stored values.

## Coordination warning

Another session is concurrently adding an **ODBC module** to this repo —
`src/eval.c` and the Makefile are already modified, and `odbc_money_text` is
part of that work. A money representation change collides with it directly.
Please sequence the two deliberately rather than discovering the conflict in a
merge.

## Suggested order

1. **`*` and `/` staying in integer arithmetic** — the silent-corruption fix,
   worth doing first even though it is the least visible.
2. **Exact construction from decimal text** — small, and it alone makes the
   existing range reachable.
3. **Guard digits and per-currency scale** — the representation change above,
   which is the part that needs a design ruling before code.

## Tests worth pinning

Exact construction at the top of the range; no precision loss through `*` and
`/`; guard digits actually retained across a multi-step calculation (the
motivating case: several operations, rounded to presentation only at the end,
compared against the exact expected result); the display rounding rule at the
boundary; and refusal of excess decimals.

## What is not being asked

gdash does not need any of this to keep working — it carries money as decimal
text and int64 in SQLite and never constructs a `money` value. The value of
the change is consolidation: with an exact constructor and integer-preserving
arithmetic, gdash's own `from_minor`/`format_currency` string surgery can
delegate to the platform, and money is done correctly in one place instead of
two.
