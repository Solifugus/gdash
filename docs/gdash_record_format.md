# gdash record format — `format: 1`

A dashboard is one JSON record. This document is the contract: every key, what
it means, whether it is required, and what refuses it. It describes `format: 1`
as a stable format, not as a snapshot of current code.

A record contains no credentials, ever (design §2). Connection profiles are
server-level and live in `/etc/gdash/connections.json` (0600).

---

## 1. Top level

| key | required | meaning |
|---|---|---|
| `format` | yes | Format version. Must be `1`. |
| `name` | yes | Identifier for the dashboard. |
| `title` | no | Shown as the page heading. Defaults to `name`. |
| `access` | no | `open` is the only value this build understands. **Absent means closed** — see §7. |
| `datasets` | yes | Object of dataset name → dataset. |
| `params` | no | Object of param name → `{ default }`. |
| `controls` | no | Object of control name → control. |
| `visuals` | yes | Object of visual name → visual. |
| `tabs` | yes | Non-empty array of tabs. |

## 2. Datasets

A dataset materializes a source query into a local SQLite file. Its name
becomes a table name, so it must be a legal SQL identifier.

| key | required | meaning |
|---|---|---|
| `profile` | yes | Names a server-level connection profile. |
| `sql` | yes | The fetch query, in the **source's** dialect. |
| `refresh` | no | `manual` only in this build. |
| `columns` | no | Column name → `{ type, scale, currency }`. |

**Params may not appear in a dataset query.** A param there would make a slicer
change re-fetch from the source, silently reintroducing pass-through cost
(design §2). This is enforced at load time.

### Money columns

`{ "type": "money", "scale": s, "currency": "USD" }` materializes as an
INTEGER scaled by 10^s, with per-column scale recorded in `_gdash_meta` inside
the dataset file. **Source values with more decimals than `s` are rejected, not
rounded.** `currency` defaults to `USD` and must be one this build supports:
USD, EUR, GBP, JPY, CHF, CAD, AUD, KWD.

Undeclared columns map: integer-looking → INTEGER, numeric → REAL, else TEXT.

## 3. Params and controls

A param declares a default. Controls publish a param:

```json
"region_picker": {
  "kind": "select", "param": "region", "dataset": "orders",
  "label": "Region", "sql": "select distinct region as value from orders order by 1"
}
```

`kind` is `select` in this build. A control's `sql` runs against its dataset;
the **first result column** supplies the option values.

### The dependency graph is derived, never declared

The server scans query text for `:name` bindings. When a control publishes a
new value, **exactly the visual queries whose text binds that param re-run**. A
visual that does not bind it deliberately stays put. There is no wiring section
to drift out of sync with the SQL.

A `:name` inside a string literal, a quoted identifier, or a comment is not a
binding, and `::` is a cast.

## 4. Visuals

A visual is a dataset + a SQL query (in **SQLite** dialect, against the
materialized dataset) + an encoding.

| key | required | meaning |
|---|---|---|
| `dataset` | yes | Which dataset to query. |
| `sql` | yes | The visual query. May bind `:params`. |
| `encoding` | yes | Mark plus channel mapping. |

### Marks and their channels

| mark | channels | notes |
|---|---|---|
| `bar` | `x`, `y`, optional `series` | |
| `line` | `x`, `y`, optional `series` | |
| `value` | `value` | A single figure. |
| `table` | *none* | Renders result columns in SELECT order. |

`series` names a column whose distinct values become one chart series each, in
result order. A missing `(x, series)` pair renders as a **gap**, not a zero.

`table` takes no `x`/`y`/`series`: the SQL is the single place shape is
decided, so setting one is refused rather than ignored.

### Formats

`format` (scalar marks) or `formats` (a `table`'s column → format map) selects
display formatting. A format entry is either a bare name or an object with
options:

```json
"formats": { "total": "currency", "share": { "name": "percent", "decimals": 1 } }
```

| format | options | notes |
|---|---|---|
| `currency` | — | Uses the column's scale and the encoding's `currency`. |
| `number` | `decimals` | Thousands-grouped. |
| `percent` | `decimals` | Renders a ratio as a percentage. |
| `text` | — | Default. |

**Currency range.** Formatting goes through gBASIC's money type, an exact
int64 at the currency's storage scale (its minor-unit exponent plus four guard
digits). For USD that caps rendering at **$9,223,372,036,854.77**. gdash's own
storage is unaffected — SQLite holds the exact integer either way — but a
value above the ceiling **refuses to render** rather than falling back to a
second formatting path with different rounding.

## 5. Layout

`tabs` is an array of `{ name, layout }`. Each `layout` is a tree of
containers and leaves.

- **Containers**: `{ "vert": [...] }` or `{ "horiz": [...] }`.
- **Leaves**: `{ "visual": "name" }` or `{ "control": "name" }`.

Any node may carry:

| key | meaning |
|---|---|
| `weight` | A positive number. The child flexes; without one it takes natural size. |
| `gap` | Non-negative. Inter-child spacing, in pixels. |
| `space` | `between`, `around`, `evenly`, `start`, `end`, `center`. Governs **leftover** room. |

**Dead `space` warns.** When every child of a container is weighted there is no
leftover room, so `space` does nothing. That is a warning, not a refusal: the
record still loads, and the setting is still emitted so the page does not
disagree with the record.

All tabs render server-side in one response and switch on the client, because
workers share no in-memory state (design §5). Params are shared across tabs.

## 6. What load-time validation cannot check

A dashboard validates completely before any source database is contacted —
with one documented gap.

**Encoding channel names are not checked at load time.** Doing so needs
prepare-without-execute (`sqlite.columns`), which has not shipped in gBASIC.
Until it does, a channel naming a column the query does not return is caught
**when the visual first renders**, and shows as an error in that visual's cell
rather than refusing the record. This is design §2's stated fallback, and it is
the one respect in which load-time red/green is partial.

## 7. Access

`access: open` is a **per-dashboard opt-in, never a server default**. A record
with no `access` key is refused with 403. A half-configured server fails
closed.

This build implements no identity: `open` is the only mode it can honour, and
saying so is what keeps the default closed rather than leaving a window in
which "no auth yet" quietly means "open to all".

---

## Appendix — the refusal catalog

Every diagnostic this build emits, verbatim. **Generated from
`tests/goldens/validation.golden`**; the suite fails if this section and that
file disagree, so the two cannot drift. Each entry names a case and the
diagnostics it produces.

<!-- BEGIN GENERATED CATALOG -->
```
format missing
  ERROR record has no 'format'
  ERROR record has no tabs
format unsupported
  ERROR unsupported record format: 99 (this build reads format 1)
  ERROR record has no tabs
name missing
  ERROR record has no 'name'
  ERROR record has no tabs
access unsupported
  ERROR unsupported access mode: 'public' (this build understands 'open')
  ERROR record has no tabs
datasets missing
  ERROR record has no 'datasets' object
  ERROR record has no tabs
visuals missing
  ERROR record has no 'visuals' object
  ERROR record has no tabs
tabs missing
  ERROR record has no 'tabs' array
tabs empty
  ERROR record has no tabs
dataset illegal name
  ERROR dataset name is not a legal SQL identifier: '2bad'
dataset sql missing
  ERROR dataset 'd1' has no 'sql'
dataset profile missing
  ERROR dataset 'd1' has no 'profile'
dataset binds a param
  ERROR dataset 'd1' binds param ':region'; params may appear only in visual queries
dataset refresh policy
  ERROR dataset 'd1' uses refresh policy 'hourly'; the policies are 'manual', 'on_open' and 'interval'
interval without a period
  ERROR dataset 'd1' refreshes on an interval but has no 'every' (seconds)
interval period not a whole number
  ERROR dataset 'd1' has 'every' of '0.5'; it must be a whole number of seconds, at least 1
period without an interval
  ERROR dataset 'd1' sets 'every' but its refresh policy is 'manual'; 'every' belongs only to 'interval'
min_age without on_open
  ERROR dataset 'd1' sets 'min_age' but its refresh policy is 'manual'; 'min_age' belongs only to 'on_open'
min_age not a whole number
  ERROR dataset 'd1' has 'min_age' of '-1'; it must be a whole number of seconds, zero or more
too many datasets
  ERROR dashboard has 12 datasets; SQLite attaches at most 10 beside the one being queried, so 11 is the limit
money scale missing
  ERROR money column 'd1.amt' has no 'scale'
money scale negative
  ERROR money column 'd1.amt' has a non-integer or negative scale
money currency unsupported
  ERROR money column 'd1.amt' names currency 'XYZ', which this build does not support
visual dataset missing
  ERROR visual 'v1' has no 'dataset'
visual dataset unknown
  ERROR visual 'v1' names undefined dataset 'nope'
visual sql missing
  ERROR visual 'v1' has no 'sql'
visual binding unresolved
  ERROR visual 'v1' binds ':ghost', which is not a declared param
visual encoding missing
  ERROR visual 'v1' has no 'encoding'
visual mark missing
  ERROR visual 'v1' encoding has no 'mark'
visual mark unknown
  ERROR visual 'v1' uses mark 'sankey'; this build renders bar, line, value and table
bar missing channels
  ERROR visual 'v1' mark 'bar' needs both 'x' and 'y' channels
value missing channel
  ERROR visual 'v1' mark 'value' needs a 'value' channel
table with channels
  ERROR visual 'v1' mark 'table' takes no x, y or series channel; it renders result columns in SELECT order
series on wrong mark
  ERROR visual 'v1' sets 'series', which only mark 'bar' or 'line' uses
format unknown
  ERROR visual 'v1' uses format 'sparkline'; this build renders currency, number, percent and text
formats on wrong mark
  ERROR visual 'v1' sets 'formats', which only mark 'table' uses
formats unknown name
  ERROR visual 'v1' formats column 'a' as 'sparkline'; this build renders currency, number, percent and text
visual currency unsupported
  ERROR visual 'v1' names currency 'XYZ', which this build does not support
control kind
  ERROR control 'c1' has kind 'radio'; this build implements 'select'
control param missing
  ERROR control 'c1' has no 'param'
control param undeclared
  ERROR control 'c1' publishes ':ghost', which is not a declared param
control dataset unknown
  ERROR control 'c1' names undefined dataset 'nope'
tab name missing
  ERROR tab[0] has no 'name'
tab layout missing
  ERROR tab[0] has no 'layout'
layout leaf unknown visual
  ERROR tab[0].layout.vert[0]: layout leaf names undefined visual 'ghost'
layout leaf unknown control
  ERROR tab[0].layout.vert[0]: layout leaf names undefined control 'ghost'
layout node unrecognised
  ERROR tab[0].layout.vert[0]: layout node must be vert, horiz, visual or control
layout container not array
  ERROR tab[0].layout.vert must be an array
space illegal
  ERROR tab[0].layout: 'space' is 'justify'; it must be between, around, evenly, start, end or center
gap negative
  ERROR tab[0].layout: 'gap' must be a non-negative number
weight zero
  ERROR tab[0].layout.vert[0]: 'weight' must be a positive number
WARNING dead space
  WARN  tab[0].layout: 'space' is ignored because every child is weighted, so there is no leftover room to distribute
```
<!-- END GENERATED CATALOG -->
