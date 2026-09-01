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
| `access` | no | `open` is the only value this build understands. **Absent means closed** — see §9. |
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
| `refresh` | no | `manual` (default), `on_open`, or `interval`. |
| `every` | with `interval` | Seconds between refreshes. A whole number, at least 1. Refused with any other policy. |
| `min_age` | `on_open` only | Seconds. Suppresses the request while the data is younger than this. Refused with any other policy. |
| `columns` | no | Column name → `{ type, scale, currency }`. |

**Params may not appear in a dataset query.** A param there would make a slicer
change re-fetch from the source, silently reintroducing pass-through cost
(design §2). This is enforced at load time.

**A dashboard may name at most eleven datasets.** A visual query attaches every
sibling dataset so it can be named unqualified (§4), and SQLite attaches at most
ten databases beside the one being queried. The twelfth is refused at load
rather than at render.

### Refresh policies

`refresh` is a string, and its companions are sibling keys rather than a nested
object, because `format: 1` published it as a string.

- **`manual`** — refreshes only when a person asks: the CLI's `refresh` verb or
  the dashboard's refresh button.
- **`on_open`** — opening the dashboard *requests* a refresh; the scheduler
  performs it. The page does **not** wait: it renders the data it has, and the
  open tabs are told over SSE when the new data lands. Twenty people opening one
  dashboard file one request between them, because a request already pending is
  not duplicated.
- **`interval`** — refreshed every `every` seconds. A failed attempt counts as
  an attempt, so a source that is down is retried on the dataset's own cadence
  rather than at whatever rate the scheduler ticks.

Two things bound what a policy can do:

- **Draft datasets refresh manually only** (design §3). A policy applies to a
  dashboard that has been published; a draft's `interval` is inert until then,
  and a policy-triggered refresh against a draft is refused by name.
- **Policies need a scheduler running.** There is no timer inside the server —
  the platform's `server` block has one hook and it is `on drain` — so
  `gdash_scheduler.bas` (or `gdash schedule` from cron) is what makes `on_open`
  and `interval` mean anything. With none running, every dataset behaves as
  `manual`: the dashboard serves the data it has and says how old it is.

**An unchanged refresh does not bump the version.** The fetched content is
hashed; when it matches what is already stored, the staging file is discarded
and no reload is broadcast. Otherwise a five-minute interval over static data
would reload every open tab twelve times an hour to show the same numbers.

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

**A visual query may name any dataset of its dashboard, unqualified.** The
named `dataset` is opened directly and every sibling is attached under its own
name, so `from orders join regions on ...` works with no prefix and no wiring —
the cross-source join of design §3, arriving as ordinary SQL. A sibling that has
never refreshed is not attached, and a query naming it fails with SQLite's own
message, shown in place of that one visual.

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

**A cross-dataset query is not checked at load time either**, for the same
reason and one more: whether a sibling dataset's table exists depends on
whether that dataset has ever refreshed, which is a fact about the cache and
not about the record. A join against a dataset that has never refreshed fails
in that visual's cell and nowhere else.

## 7. What a viewer is told about the data

Every dashboard carries one status line **per dataset**: when that dataset last
refreshed successfully, and — when the most recent attempt failed — what the
source said. One line for a whole dashboard stops being true the moment two
datasets diverge, which is exactly when a viewer needs it.

A failed refresh never disturbs the data. The old dataset file is untouched,
every visual keeps rendering, and the status line says the last refresh failed.
Stale-but-coherent beats broken (design §3) — but only if the viewer is told,
which is what this line is for.

**A dataset whose definition changed says so too.** The state records the
`profile` and `sql` that produced what is on disk. When the record now being
served asks a different question — after an edit and a publish, or after a
rollback to a version whose dataset differs — the status line says the data
predates the record, and the scheduler treats that dataset as due whatever its
interval. A `manual` dataset says the same thing and waits for a person,
because a manual dataset waiting for a person is what `manual` means.

The refresh that follows often changes nothing: a query can be rewritten and
still return the same rows. The version does not bump, no one reloads, and the
warning clears anyway — the record and its data agree again, which is what the
warning was about.

## 8. Publishing, and what a viewer sees across one

A record is edited as `draft.json` and published to an immutable snapshot;
`current` names the snapshot in force. This document describes the *record*,
so the lifecycle lives in design §7 — but two of its consequences are visible
to a viewer and belong here:

- **A viewer is pinned to the snapshot they opened.** Publishing does not move
  a reader mid-session; the pin is a session cookie scoped to that dashboard,
  and it ends when the browser does. No one sees a half-updated dashboard.
- **A publish is announced, not applied.** Open tabs receive a `publish` event
  and show a banner offering a reload. A data `refresh` still reloads by
  itself, because new numbers under the same record are what a dashboard is
  for; a new record is a different thing and the viewer decides when to take
  it.

**A draft that does not validate cannot be published.** Publishing runs the
full validation in this document and refuses on any error — warnings do not
block. Nothing is written and `current` does not move.

## 9. Access, groups, and identity

| key | required | meaning |
|---|---|---|
| `access` | no | `open` is the only value. **Absent means closed.** |
| `view_groups` | no | Array of group names that may view. |
| `edit_groups` | no | Array of group names that may publish, roll back and refresh. |

Resolution, in order, and failing closed at every step:

1. `access: open` — served to anyone, signed in or not. A **per-dashboard
   opt-in, never a server default**: a half-configured server must not serve.
2. Otherwise the viewer must be signed in **and** in one of `view_groups` or
   `edit_groups`. An editor can always see what they may change; the reverse
   is not true, and `edit` never falls back to `view`.
3. An administrator needs no group.
4. Anything else is refused. A record naming no groups and no `access` is
   visible to administrators only.

**A viewer who is not signed in is told the dashboard does not exist** — 404,
not 403. On an intranet the existence of a dashboard called `layoffs-q3` is
itself information, and 403 confirms it. A viewer who *is* signed in and
simply lacks the group gets 403: for them the secret is their access, not the
dashboard's existence. Version history follows the same rule as the dashboard.

### Identity in a query

The reserved params (design §2) are supplied by the server from the signed-in
identity and **may not be declared** by a record — declaring one would let an
author give it a default and believe they had configured something the server
overwrites unconditionally.

| param | value |
|---|---|
| `user_name` | the signed-in username, or `""` |
| `user_email` | their address, or `""` |
| `user_groups` | their groups, delimited: `\|analysts\|finance\|` |

`user_groups` is delimited **at both ends** so that
`:user_groups like '%\|finance\|%'` cannot match a group merely ending in
`finance`. An anonymous viewer gets `\|\|` — the same encoding with nothing in
it, so a query written for the signed-in case behaves the same way rather than
hitting a different one.

**They are injected, never merged.** A client that sends `?user_email=...`
is ignored. This is the whole of design §5's claim that a user-filtered
dashboard over a shared dataset is genuinely secure: the filtering happens
server-side against an identity the client cannot state.

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
reserved param declared
  ERROR param 'user_email' is reserved; the server supplies it from the authenticated identity
access not open
  ERROR unsupported access mode: 'public' (this build understands 'open')
view_groups as a bare string
  ERROR 'view_groups' must be an array of group names; a bare string is not a list of one
edit_groups with an empty entry
  ERROR 'edit_groups' contains an entry that is not a group name
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
