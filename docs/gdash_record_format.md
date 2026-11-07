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

A dataset materializes a source query into a table in the dashboard's local
G-SQL database. Its name becomes the table's name, so it must be a legal SQL
identifier, and it may not start with `_gdash` or end in `__staging`: those
are the store's own tables.

| key | required | meaning |
|---|---|---|
| `profile` | yes | Names a server-level connection profile. |
| `sql` | yes | The fetch query, in the **source's** dialect. |
| `refresh` | no | `manual` (default), `on_open`, or `interval`. |
| `every` | with `interval` | Seconds between refreshes. A whole number, at least 1. Refused with any other policy. |
| `min_age` | `on_open` only | Seconds. Suppresses the request while the data is younger than this. Refused with any other policy. |
| `columns` | no | Column name → `{ type, … }`. `type` is `money` (with `scale`, `currency`) or `date`; any other type is refused by name. |

**Params may not appear in a dataset query.** A param there would make a slicer
change re-fetch from the source, silently reintroducing pass-through cost
(design §2). This is enforced at load time.

**There is no limit on how many datasets a dashboard names.** Every dataset is
a table in the same database, so a visual query reaches each sibling by name
(§4). Until GDASH-20 SQLite's attach limit capped a dashboard at eleven.

### Where a dataset comes from

`profile` names an entry in `/etc/gdash/connections.json`. gdash **imports**
from a source on a schedule and stages the result in G-SQL; it never queries a
source to answer a page. So a profile is an origin, not a database gdash
speaks:

```json
{ "warehouse": { "kind": "postgres", "host": "db", "database": "erp",
                 "user": "gdash", "password": "…" },
  "legacy":    { "kind": "odbc",
                 "connection": "Driver=ODBC Driver 18 for SQL Server;Server=…;UID=…;PWD=…" },
  "byDsn":     { "kind": "odbc", "dsn": "warehouse" } }
```

| kind | reaches |
|---|---|
| `postgres` | PostgreSQL directly |
| `odbc` | anything with a driver installed on the host — SQL Server, MySQL, MariaDB, Oracle, DB2, Snowflake, SQLite |
| `fixture` | a JSON file; the test seam, not a deployment source |

An `odbc` profile names either a `connection` string or a `dsn`. A DSN needs
`odbc.ini` configured; a connection string does not, and a host with drivers
and no DSNs is the ordinary case. Run `gdash source check <profile>` to see
which drivers the host can actually load.

**A connection string is a credential** — it carries `PWD=`. It lives in
`connections.json` at 0600 and appears in no record, no log, no error message
and no diagnostic.

### Refresh policies

`refresh` is a string, and its companions are sibling keys rather than a nested
object, because `format: 1` published it as a string.

- **`manual`** — refreshes only when a person asks: the CLI's `refresh` verb or
  the dashboard's refresh button.
- **`on_open`** — opening the dashboard *requests* a refresh; the scheduler
  performs it. The page does **not** wait: it renders the data it has, and each
  open tab notices when the new data lands, on its next poll of the version
  endpoint — within about five seconds. Twenty people opening one
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
hashed; when it matches what is already stored, the staging table is discarded
and no reload is broadcast. Otherwise a five-minute interval over static data
would reload every open tab twelve times an hour to show the same numbers.

### Money columns

`{ "type": "money", "scale": s, "currency": "USD" }` materializes as a
`money(USD)` column: gBASIC's own money, stored **exactly as the source gave
it**, with its currency. `s` is the **display** scale: a person is shown `s`
places, rounded half-even, and nothing else is ever rounded. A source value of
`1250.7512` in a column at scale 2 is stored as `1250.7512`, summed at that
value, and shown as `$1,250.75`. So a table's rounded rows may not add up
exactly to its rounded total; that is the honest result, where rounding at
import would make the stored figures wrong.

What is still refused: a value the currency cannot hold. Money keeps the
currency's minor unit plus four guard digits (USD six places, JPY four), so a
seventh decimal of USD fails the refresh, naming the row and column, and the
old data stays. A `scale` larger than the currency stores is refused at load.
`currency` defaults to `USD` and must be a code ISO 4217 defines — all 178 of
them. A code it does not define is refused rather than rendered as dollars.

### Date columns

`{ "type": "date" }` materializes as a native date. The source must send
ISO-8601 (`2026-01-15`); anything else (`01/15/2026`, an impossible
`2026-02-30`) fails the refresh, naming the column, and the old data stays.
That is the same "rejected, not coerced" stance as money. A date compares
with a date param, or with a date written as text (`day >= '2026-01-20'`).
Take parts of it with `extract(month from day)`, not `substring`. Its first
and last day are recorded at every refresh as the dataset's coverage, which a
`daterange` control shows.

Undeclared columns are inferred from the fetched rows: integer-looking →
`integer` (exact past 2^53), numeric → `number`, else `string`.

## 3. Params and controls

A param declares a default, and may declare a `type`: `string`, `integer`,
`number`, `date` or `money` (with an optional `currency`, `USD` by default). A
value arriving from the page is converted to its type before any query runs,
and one that does not convert is **refused by name** (HTTP 400), not coerced
and not replaced by the default. A param with no `type` is bound exactly as it
arrives, as it always was.

```json
"params": { "since": { "default": "2026-01-01", "type": "date" },
            "region": { "default": "west" } }
```

Controls publish a param:

```json
"region_picker": {
  "kind": "select", "param": "region", "dataset": "orders",
  "label": "Region", "sql": "select distinct region as value from orders order by 1"
}
```

A control's `sql` runs against its dataset; the **first result column**
supplies the option values. There are three kinds.

**`select`** publishes one value, as above.

**`multiselect`** publishes a **list written `|a|b|`**, with delimiters at
both ends. `||` means none chosen. A query tests membership with the
delimiters on both sides of the column:

```sql
where :regions = '||' or :regions like '%|' || region || '|%'
```

The delimiters are load-bearing. `|west|` must not match `northwest`, and
without the leading `|` it would. The first clause makes "none chosen" mean
"all"; leave it out if none should mean none. A list's default must be
`|…|`-shaped, and an option whose value itself contains `|` cannot be offered
(the control says how many were left out). It is the same convention
`user_groups` uses.

**`daterange`** publishes an **expression**, and gdash turns it into two
dates on every request:

```json
"params":   { "period": { "default": "last_30d" },
              "since":  { "default": "2026-01-01", "type": "date" },
              "until":  { "default": "2026-12-31", "type": "date" } },
"controls": { "when": { "kind": "daterange", "param": "period",
                        "from": "since", "to": "until",
                        "dataset": "orders", "column": "day" } }
```

- **The vocabulary is closed:** `today`, `last_7d`, `last_30d`, `last_90d`,
  `mtd`, `qtd`, `ytd`, `last_month`, `last_quarter`, `last_year` and `custom`.
  An unknown expression is refused at load and at request time.
- **The SQL binds the two dates**, `where day >= :since and day <= :until`,
  and both bounds are inclusive.
- **A relative expression is resolved per request, against today.** A
  bookmark holds `last_30d`, not the dates it meant when it was saved.
- **`custom` uses the two date params as given**, and a bookmark carries them.
- **Both date params must be declared with `type: date`,** and `column` must
  be declared `{"type": "date"}` in its dataset.

**The control shows what the data covers.** It prints "data covers X to Y",
from the date column's coverage recorded at the dataset's last refresh, and
**flags a range that reaches outside it**. A range past the imported data
would otherwise draw an empty chart that reads as "nothing happened" rather
than "this was not imported". A dataset refreshed before coverage was
recorded says "coverage unknown".

**The page keeps its params, and the URL carries them.** Every change sends
the page's whole state, and the address bar is updated, so a bookmark reopens
the same view. **Reset** is a link to the bare path, which is every control at
its default.

**Drill to detail is a pattern, not a feature.** Give a chart
`"publishes": "<param>"`, and add a `table` visual whose query binds the same
param. A click on a bar then fills the table with that bar's rows. A drill
through levels (region, then country, then city, with breadcrumbs) is
deliberately not built (GDASH-19 brief).

**A query may not write its own positional placeholder.** gdash rewrites every
`:name` into `$1`, `$2`, … itself, so a hand-written `$1` would silently take
the value of gdash's first binding, and a `?` is a placeholder no argument
accounts for. Both are refused by validation. Inside a string literal or a
comment they are text, and left alone.

### The dependency graph is derived, never declared

The server scans query text for `:name` bindings. When a control publishes a
new value, **exactly the visual queries whose text binds that param re-run**. A
visual that does not bind it deliberately stays put. There is no wiring section
to drift out of sync with the SQL.

A `:name` inside a string literal, a quoted identifier, or a comment is not a
binding, and `::` is a cast.

## 4. Visuals

A visual is a dataset + a SQL query (in **G-SQL**, gBASIC's own SQL, against
the materialized data) + an encoding.

**G-SQL in brief, for an author coming from SQLite or PostgreSQL.** Values keep
their gBASIC kinds: money is money, and an integer is exact. A plain number or
a text literal compared with a typed column is read as that column's kind, so
`amount > 1000` means USD 1000 and `day >= '2026-10-01'` compares dates; kinds
that do not compare (a date and a number, dollars and yen) are refused, and so
is arithmetic across currencies. Text joins with `||`. Each of these has one
spelling:

- `substring(x, start [, length])`, counting characters from 1; there is no
  `substr` and no `FROM … FOR` form.
- `extract(part FROM value)`, where `part` is `year`, `quarter`, `month`,
  `week` (ISO), `day`, `hour`, `minute` or `second`.
- `GROUP BY` takes a position (`group by 1`) or an output alias. A name that
  is also a column means the column, as in PostgreSQL.

These need gBASIC `0424a49` or later.

| key | required | meaning |
|---|---|---|
| `dataset` | yes | Which dataset to query. |
| `sql` | yes | The visual query. May bind `:params`. |
| `encoding` | yes | Mark plus channel mapping. |

**A visual query may name any dataset of its dashboard, unqualified.** Every
dataset is a table in the dashboard's one database, so `from orders join
regions on ...` works with no prefix and no wiring — the cross-source join of
design §3, arriving as ordinary SQL. It cannot name another dashboard's data:
that is a different database. A sibling that has never refreshed has no table,
and a query naming it fails with G-SQL's own message, shown in place of that
one visual. Every visual query runs read-only at the engine.

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

### The marks

| mark | channels | draws |
|---|---|---|
| `bar` | `x`, `y`, optional `series` | A bar per category, grouped or stacked. Takes a **text or numeric** `x`. |
| `line` | `x`, `y`, optional `series` | A line per series. **Needs a numeric `x`.** |
| `area` | `x`, `y`, optional `series` | A filled band per series. Needs a numeric `x`. |
| `scatter` | `x`, `y`, optional `series` | A point per row, unjoined. Needs a numeric `x`. |
| `pie` | `label`, `value` | One slice per label. No axes, no `series`, no legend — it labels its slices directly. |
| `value` | `value` | A single figure. |
| `table` | none | Result columns in SELECT order. |

`histogram`, `heatmap` and `sparkline` are **not** implemented, and the reasons
are in the phase brief: a histogram bins raw rows, which is aggregation the SQL
should be doing; a heatmap needs a two-dimensional channel vocabulary no other
mark uses; a sparkline belongs in a table cell and the table mark has no
cell-renderer concept.

### Chart options

Marks with axes — `bar`, `line`, `area`, `scatter` — accept these; every one is refused on a mark that
cannot use it, and refused again if it is the wrong type.

| key | type | meaning |
|---|---|---|
| `title` | text | Drawn inside the chart. Until GDASH-7 a chart mark's title was accepted and rendered by nobody. |
| `x_label` / `y_label` | text | Axis labels. |
| `legend` | boolean | Defaults to **on when a `series` channel is bound**, off otherwise — one line needs no key to say which line it is. |
| `stacked` | boolean | `bar` and `area` only. |
| `grid` | boolean | Gridlines. On by default. |
| `y_min` / `y_max` | number | Axis range. `y_min` at or above `y_max` is refused. |
| `publishes` | text | A param a click on a mark publishes. `bar`, `scatter`, `pie` only. |

**The axis follows the format; you do not set it twice.** A visual that says
`format: "currency"` with a `currency` gets that currency's symbol on the axis
and its own number of minor units — `$1,250.75`, and `¥1,251` for a currency
with none. `format: "percent"` labels the axis `42%` where the value is stored
as `0.42`, which is the same hundred the table multiplies by. There is no
`y_prefix` in the record on purpose: a second place to declare the format is a
second place to forget it, and then the axis and the numbers beside it
disagree on one page.

**A range is the author's decision and gdash does not supply one.** An axis
that does not start at zero can mislead, and an axis forced to zero can bury
the signal; which is honest depends on what the chart is for, so the record
says or the library decides.

**A `line` needs a numeric `x`.** Given a text column it is refused, by name,
with the suggestion to use `bar` — because the chart library draws nothing at
all for a categorical x and returns a complete, empty-looking chart. That is a
platform limitation gdash reports rather than hides; if it lifts, the refusal
goes away and a period-labelled time series becomes a line chart.

### Large results: downsample in SQL

A chart of a hundred thousand points is a SQL problem, not a rendering one.
Design §2 puts shape in the query, and that includes how much of it there is.

Measured on this build, a single-series line chart:

| points | render |
|---|---|
| 500 | ~0.1 s |
| 1000 | ~0.3 s |
| 2000 | ~0.5 s |
| 4000 | ~1.0 s |

Roughly linear, dominated by the chart library's own SVG assembly. A few
thousand points is comfortable; a hundred thousand is not, and it would not be
readable either — a 640-pixel-wide chart cannot show more points than it has
pixels.

**Bucket and aggregate**, so the query returns one row per thing the eye can
actually resolve:

```sql
-- daily rows, one point per week
select cast(strftime('%W', day) as integer) as week,
       sum(amount)                          as total
from   orders
group  by week
order  by week

-- a long numeric series, one point per hundredth of its range
select cast(reading / 100 as integer) * 100 as bucket,
       avg(value)                           as value
from   samples
group  by bucket
order  by bucket
```

**gdash does no aggregation of its own** and will not grow any: a `group by`
you wrote is a decision you can see, read and change, and one gdash inferred
would be a second place shape is decided. If a chart is slow, the query is
returning more than the chart can draw.

### Click a mark, publish a param

A `bar`, `scatter` or `pie` can name a param that a click on one of its marks
publishes:

```json
"encoding": { "mark": "bar", "x": "region", "y": "total", "publishes": "region" }
```

A click then does exactly what moving a `select` control does — it publishes a
param, and precisely the visuals whose SQL binds that param re-run. There is
one publish path for both, so a click cannot become a second, subtly different
way to change a param.

**Only marks that are categories.** A `line` cannot publish: its mark is a
whole series, not a category, so a click on it has nothing to mean. That is
measured against the chart library rather than assumed — a bar, a point and a
slice each carry their value, a line's path does not.

**A visual that does not set `publishes` is unchanged in every byte.** The
identifiers the click needs are switched on per visual, so a dashboard that has
not asked for this renders what it always rendered.

The param must be declared, and may not be one of the reserved `user_*` —
those come from the signed-in identity and a click may not overwrite them.

### Colour, and the theme

A dashboard describes what it shows; **how it looks belongs to the
deployment**, so that a company's dashboards agree with each other without
every record repeating the same palette.

`/etc/gdash/theme.json` — server-level, not restricted (it holds no
credential):

```json
{ "format": 1,
  "palette": ["#111111", "#E69F00", "#56B4E9"],
  "font_size": 14 }
```

**Absent means the chart library's own defaults**, which are the Okabe–Ito
palette — colourblind-safe by construction, and a better default than gdash
would have picked for itself. A theme file is an override, never a requirement.

**Malformed also means the defaults**, plus an error in the audit log. That is
the opposite of the ruling for `users.json`, where a file gdash cannot read is
a locked door quietly removed and everything fails closed. The difference is
that one governs access and the other governs appearance: refusing to serve a
dashboard because its colours are unreadable would be a worse failure than
serving it in the wrong colours.

A record may override **one** thing — the colour of a named series or pie
slice:

```json
"encoding": { "mark": "line", "x": "period", "y": "total", "series": "region",
              "colors": { "south": "#d55e00" } }
```

Because "that series is red in every other report in the company" is a real
reason, and nothing else about appearance is. A colour is `#abc` or `#1a2b3c`;
named colours and `rgb()` are refused, because the value goes straight into SVG
markup and a short checkable grammar is what keeps it from being an injection
surface. A name the record does not colour takes the next **unused** theme
colour, so overriding one series never silently recolours another.

### Formats

`format` (scalar marks) or `formats` (a `table`'s column → format map) selects
display formatting. A format entry is either a bare name or an object with
options:

```json
"formats": { "total": "currency", "share": { "name": "percent", "decimals": 1 } }
```

| format | options | notes |
|---|---|---|
| `currency` | — | Shows the column's display scale, half-even. A money value renders in its own currency; a stated `currency` that disagrees with it is refused. A plain number renders in the stated currency, USD when none is stated. |
| `number` | `decimals` | Thousands-grouped. |
| `percent` | `decimals` | Renders a ratio as a percentage. |
| `text` | — | Default. |

**Currency range.** Formatting goes through gBASIC's money type, an exact
int64 at the currency's storage scale (its minor-unit exponent plus four guard
digits). The ceiling therefore **moves with the currency**: USD stops at
`9,223,372,036,854.77`, KWD at `922,337,203,685.477`, and JPY — which has no
minor unit — at `922,337,203,685,477`. Since GDASH-20 the store holds the
same money type, so a source value above the ceiling fails its refresh, and a
`sum` that overflows it fails its visual (warning 2112). A plain number above
the ceiling **refuses to render**, naming that currency's own limit.

Symbols are given for USD, EUR, GBP and JPY; every other currency renders as
its code and the amount (`NGN 1,234.56`), because ISO 4217 defines codes and
not symbols.

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

## 6. What validation checks against the staged data

A dashboard validates completely before any source database is contacted.
Since GDASH-21 there is a second pass, against the **draft's staged data**,
which `gdash validate` runs and `gdash publish` enforces:

- every visual's query is **described from its plan, with nothing run** (G-SQL's
  `db.columns`). A query that does not compile is an error;
- every channel (`x`, `y`, `series`, `value`, `label`) and every key of a
  `table`'s `formats` must name a column the query returns. One that does not
  is an error, naming the column and listing what the query does return;
- every control's options query must compile;
- a `currency` format over a column that is plainly not an amount (text, a
  date, a boolean) is a **warning**.

`publish` refuses on any error, and nothing is published.

**Two limits.**

- **The staged data must exist.** A column list comes from the query's plan,
  and a dataset that has never refreshed has no table to plan against. Such a
  visual is reported as **not checked**, never as passing. A first publish
  before any refresh, the documented first-run order, is not refused. Those
  visuals are checked at first render, as before, and an error shows in that
  visual's cell.
- **The kind warning reaches plain columns only.** G-SQL types a column read
  straight from a table and `count(*)`. Most computed columns (`sum(amount)`,
  `amt * 2`) are described as `any`, and get no kind check.

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

### Where an identity comes from

Nothing in this table changes with the identity's source; the only difference
is who answered. Providers are consulted in one fixed order that is not
configurable:

1. **Local accounts** (`/etc/gdash/users.json`) — always, and always first.
2. **The directory**, if one is configured in `/etc/gdash/auth.json`.

Local is first because it is the break-glass tier, and break-glass that needs
the directory to be healthy is not break-glass: a directory consulted first
would take the local administrator down with it at exactly the moment somebody
needs to sign in and fix the directory configuration. The cost is that **a
local account of the same name shadows a directory account** — visible in
`gdash user list`, created by an operator on purpose, and removed with one
command, which the reverse failure is not.

The chain stops at the first provider that **has** the username, whatever it
then says about the password. One typo therefore costs one failed bind rather
than one per directory, which matters where a failed bind counts toward a
lockout.

**A directory that is down is never reported as a wrong password.** It answers
503 and "sign-in is unavailable", and the outage is audited. Telling somebody
their password is wrong when the directory is down sends them to reset a
password that was fine.

**Group membership from a directory is bounded-stale.** A directory cannot be
asked on every request, so the identity is materialized into the session at
sign-in and re-resolved every `revalidate` seconds (default 300). A group
change therefore takes effect within that window, not instantly. Local
accounts use `revalidate: 0` and are re-read on every request, so a disabled
local account stops working immediately. When a revalidation cannot reach the
directory, **the session stands** until its ordinary absolute and idle limits:
a directory outage that logs everyone out turns a directory problem into a
total outage.

## 10. Auth providers (`/etc/gdash/auth.json`)

Server-level, mode 0600, because it holds a service account's password. An
absent file means local accounts only — which is a complete configuration, not
a broken one. A file gdash cannot read or cannot validate means **local
accounts only** as well: the directory is never guessed at, and the operator
is told in the log.

```json
{ "format": 1,
  "directory": {
    "kind": "ldap",
    "name": "corp",
    "host": "dc01.corp.example",
    "port": 636,
    "security": "ldaps",
    "user_search": { "base": "OU=People,DC=corp,DC=example",
                     "filter": "(sAMAccountName={user})" },
    "bind_dn": "CN=gdash,OU=Service,DC=corp,DC=example",
    "bind_password": "…",
    "group_strategy": "memberof",
    "admin_groups": ["gdash-admins"],
    "revalidate": 300 } }
```

| key | required | meaning |
|---|---|---|
| `kind` | yes | `ldap` is the only value this build implements. |
| `name` | no | What the audit log calls this provider. Default `directory`. |
| `host` | yes | The directory. |
| `port` | no | Defaults to 389 or 636 by `security`. |
| `security` | **yes** | `ldaps`, `starttls` or `plain`. **No default.** |
| `verify` | no | TLS verification. True unless explicitly false. |
| `ca_file` | no | An intranet CA, which is the normal case rather than an exotic one. |
| `user_dn_template` | one of | e.g. `uid={user},ou=people,dc=x`. No service account needed. |
| `user_search` | one of | `{ base, filter, scope }`, with `{user}` in the filter. |
| `bind_dn` / `bind_password` | no | The service account. Anonymous otherwise. |
| `group_strategy` | **yes** | `memberof` or `search`. **No default.** |
| `group_attribute` | no | For `memberof`. Default `memberOf`. |
| `group_base` | with `search` | Where the groups live. |
| `group_filter` | no | Default `(member={dn})`. Must contain `{dn}`. |
| `group_name_attribute` | no | For `search`. Default `cn`. |
| `group_names` | no | `rdn` (default) or `dn`. |
| `email_attribute` | no | Default `mail`. |
| `name_attribute` | no | Default `cn`. |
| `admin_groups` | no | Groups whose members administer gdash. **Empty means none.** |
| `revalidate` | no | Seconds. Default 300; `0` means every request. |

Three of these have **no default on purpose**, and the reason is the same each
time: guessing produces a plausible answer rather than a failure.

- **`security`** — the platform's rule, not gdash's. A default would make a
  cleartext bind either silent or accidental; requiring it means a cleartext
  bind is a word somebody typed and is greppable in a configuration review.
- **`group_strategy`** — Active Directory populates `memberOf` natively;
  **stock OpenLDAP does not**, because the `memberof` overlay is off by
  default. A provider that reads only that attribute gets zero groups from
  OpenLDAP, zero groups is a legitimate answer, and so every group-gated
  dashboard would refuse everyone while the log showed successful logins.
- **`user_dn_template` vs `user_search`** — exactly one. A profile naming both
  or neither is refused.

Run **`gdash --root <dir> auth check <username>`** after writing this file. It
prints the DN it built, the raw group values the directory returned, and the
names gdash would use — and no password. Without it, the first evidence that
`group_strategy` is wrong is a dashboard refusing everyone.

### Preview-as

An editor answers "what does this look like to somebody in Shipping?" without
borrowing a password: a control on the page takes a name, an email and a list
of groups, and the dashboard re-renders with those as the injected `user_*`
params.

- **Draft only.** Never on a published dashboard.
- **Editors only** — the viewer must already pass `edit_groups`, or be an
  administrator.
- **Audited**, naming both the real identity and the assumed one.
- **It changes `user_*` and nothing else.** Authorization stays the real
  viewer's: preview-as cannot open a dashboard they may not open, and cannot
  make them an administrator. It is scoped to the dashboard it was set on, and
  it lives in the session rather than the URL, so it cannot be handed to
  somebody else as a link.

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
record is not an object
  ERROR record must be a JSON object
dataset is not an object
  ERROR dataset 'd1' must be an object
  ERROR dataset 'd1' has no 'sql'
  ERROR dataset 'd1' has no 'profile'
visual is not an object
  ERROR visual 'v1' must be an object
  ERROR visual 'v1' has no 'dataset'
  ERROR visual 'v1' has no 'sql'
  ERROR visual 'v1' has no 'encoding'
control is not an object
  ERROR control 'c1' must be an object
  ERROR control 'c1' has kind 'unknown'; this build implements select, multiselect, daterange
  ERROR control 'c1' has no 'param'
tab is not an object
  ERROR tab[0] must be an object
  ERROR tab[0] has no 'name'
  ERROR tab[0] has no 'layout'
params is not an object
  ERROR 'params' must be an object
controls is not an object
  ERROR 'controls' must be an object
columns is not an object
  ERROR dataset 'd1' has a 'columns' that is not an object
formats is not an object
  ERROR visual 'v1' has a 'formats' that is not an object
dataset writes a bare placeholder
  ERROR dataset 'd1' writes a positional placeholder ('?' or '$1'); gdash produces placeholders itself from ':name' and supplies no argument for a hand-written one
visual writes a bare placeholder
  ERROR visual 'v1' writes a positional placeholder ('?' or '$1'); gdash produces placeholders itself from ':name' and supplies no argument for a hand-written one
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
reserved dataset name
  ERROR dataset name 'orders__staging' is reserved: names starting '_gdash' or ending '__staging' are the store's own tables
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
  ERROR visual 'v1' uses mark 'sankey'; this build renders bar, line, area, scatter, pie, value and table
bar missing channels
  ERROR visual 'v1' mark 'bar' needs both 'x' and 'y' channels
value missing channel
  ERROR visual 'v1' mark 'value' needs a 'value' channel
table with channels
  ERROR visual 'v1' mark 'table' takes no x, y or series channel; it renders result columns in SELECT order
area needs both channels
  ERROR visual 'v1' mark 'area' needs both 'x' and 'y' channels
scatter needs both channels
  ERROR visual 'v1' mark 'scatter' needs both 'x' and 'y' channels
pie needs label and value
  ERROR visual 'v1' mark 'pie' needs both 'label' and 'value' channels
pie given axes
  ERROR visual 'v1' mark 'pie' takes 'label' and 'value', not 'x' and 'y'
pie given a series
  ERROR visual 'v1' mark 'pie' takes no 'series'; a pie is one series by construction
stacked on a scatter
  ERROR visual 'v1' sets 'stacked', which only mark 'bar' or 'area' uses
legend on a pie
  ERROR visual 'v1' sets 'legend'; a pie labels its slices directly and has no legend to turn on
publishes on a line
  ERROR visual 'v1' sets 'publishes', which only marks 'bar', 'scatter' and 'pie' can do; a line's mark is a whole series, not a category
publishes an undeclared param
  ERROR visual 'v1' publishes ':ghost', which is not a declared param
publishes a reserved param
  ERROR visual 'v1' publishes ':user_email', which is reserved; the server supplies it from the authenticated identity
publishes nothing in particular
  ERROR visual 'v1' has a 'publishes' that is not a param name
colors on wrong mark
  ERROR visual 'v1' sets 'colors', which only a mark that draws series or slices uses
colors not an object
  ERROR visual 'v1' has a 'colors' that is not an object of name to colour
colors with a bad colour
  ERROR visual 'v1' colours 'north' as 'crimson'; a colour is '#1a2b3c' or '#abc'
x_label on wrong mark
  ERROR visual 'v1' sets 'x_label', which only a mark with axes uses
y_label not text
  ERROR visual 'v1' has a 'y_label' that is not text
legend on wrong mark
  ERROR visual 'v1' sets 'legend', which only a mark with axes uses
grid not boolean
  ERROR visual 'v1' has a 'grid' that is not true or false
stacked on wrong mark
  ERROR visual 'v1' sets 'stacked', which only mark 'bar' or 'area' uses
y_min not a number
  ERROR visual 'v1' has a 'y_min' that is not a number
y_min at or above y_max
  ERROR visual 'v1' has 'y_min' at or above 'y_max'; the axis would have no height
series on wrong mark
  ERROR visual 'v1' sets 'series', which only marks with axes use
format unknown
  ERROR visual 'v1' uses format 'sparkline'; this build renders currency, number, percent and text
formats on wrong mark
  ERROR visual 'v1' sets 'formats', which only mark 'table' uses
formats unknown name
  ERROR visual 'v1' formats column 'a' as 'sparkline'; this build renders currency, number, percent and text
visual currency unsupported
  ERROR visual 'v1' names currency 'XYZ', which this build does not support
control kind
  ERROR control 'c1' has kind 'radio'; this build implements select, multiselect, daterange
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
