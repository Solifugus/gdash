# gdash — Design

**Status:** rulings from initial design sessions, Aug 2026. This is the record
of decisions and their reasons. Phase briefs cite it; when implementation
contradicts it, the contradiction is a finding to resolve, not a silent edit.

## 1. What gdash is

A dashboarding web application written in gBASIC. Comparables are PowerBI and
Tableau; gdash aims to be more seamless, more robust, and far simpler to build
and maintain. It is a product: an organization stands it up on a Linux VM in
an afternoon, typically on an intranet.

The differentiators, each a consequence of one structural choice:

- **One language.** SQL is the only computation language an author learns.
  There is no M, no DAX, no calc-language layer.
- **Text records.** A dashboard is a diffable JSON record. Version control,
  meaningful diffs between published versions, AI authoring, and hand editing
  all follow.
- **Nested flex layout.** No absolute canvas, no pixel pushing; dashboards
  reflow.
- **Explicit interaction.** Parameters are the only interaction mechanism.
  Nothing filters anything implicitly.
- **Load-time red/green.** A dashboard validates completely before any source
  database is contacted.

## 2. Record format

One JSON record per dashboard: `format` version, name/title, `access`,
`datasets`, `params`, `controls`, `visuals`, `tabs`. Reference example lives
alongside this doc; the shape rulings:

- **Datasets** name a server-level connection profile and carry the fetch SQL
  plus a refresh policy (`manual` / `on_open` / `interval`). Dataset names
  share a namespace and must be valid SQL identifiers (each becomes a table).
  Datasets are private to their record; if two dashboards fetch the same
  thing, the server MAY dedupe refresh work internally by content-hashing
  (source, query) — invisible to the format. First-class dataset sharing is
  deferred until it earns its complexity.
- **Params** declare name + default. The reserved `user_*` namespace
  (`user_email`, `user_name`, `user_groups`) is injected by the server from
  the authenticated identity — personalization is parameter binding, not a
  feature.
- **Controls** are layout leaves that publish a param. A select's options may
  come from a query over a dataset.
- **Visuals** are a dataset + a SQL query + an `encoding`: a mark type plus a
  mapping of result columns onto channels (`x`, `y`, `series`, `value`,
  `format`, ...). One record shape for all marks; expanding the chart
  vocabulary never changes the format. The `table` mark is the deliberate odd
  one out: it renders result columns in SELECT order with a per-column
  `formats` map — the SQL stays the single place where shape is decided.
- **Layout**: `tabs[]`, each a tree of `{"vert": [...]}` / `{"horiz": [...]}`
  containers. A child with `weight` flexes; a child without one takes natural
  size; `space` (`between`/`around`/`evenly`/`start`/`end`/`center`) governs
  leftover room and is ignored (with a validation warning) when every child is
  weighted; `gap` sets inter-child spacing. Leaves reference visuals or
  controls.
- **Styling stays out of the record** in v1. A server-level theme supplies
  fonts, palette, card treatment. Series colors come from a fixed categorical
  palette in result order. First styling knob to add later: per-series color
  override.
- No credentials, ever, anywhere in a record.

### Dependency semantics — derived, never declared

The server scans query text for `:name` bindings. A binding resolves against
`params`, then `user_*`, then dataset-level server-supplied constants. When a
control publishes a new value, exactly the visual queries whose text binds
that param re-run. A visual that doesn't bind the param deliberately stays
put. There is no wiring section to drift out of sync with the SQL.

**Params may appear only in visual queries.** A param in a dataset query would
make a slicer change re-fetch from the source, silently reintroducing
pass-through cost. Dataset queries get only server-supplied constants.
Enforced at validation.

### Load-time validation

Before touching any database: every binding resolves; every layout leaf names
a defined visual/control; dataset names are legal identifiers; params absent
from dataset queries; dead `space` warned. With `sqlite.columns` (planned
platform item): every encoding channel names a real result column, via
prepare-without-execute. Until then channel checks happen at first refresh.

## 3. Execution model

Two tiers:

- **Datasets** materialize source query results into local SQLite files — the
  expensive fetch, governed by refresh policy.
- **Visual queries** are plain SELECTs against those files — milliseconds,
  which is what decouples interaction cost from source cost. The source is
  touched only at refresh.

**Pass-through** (a visual query running directly against the source) is a
deferred execution policy on the same record shape, not a competing design.
V1 has none, which keeps the renderer, wiring, and format ignorant of source
dialects.

**Two dialects** (source SQL + SQLite SQL) is the accepted honest cost; still
strictly better than SQL+M+DAX. Cross-source joins fall out free: two
datasets from different sources land in the same local store; a visual query
ATTACHes and joins. Non-SQL sources (CSV, xlsx) unify by loading rows into a
dataset file — connects to the spreadsheet-engine work.

### Staging store: SQLite, and why not Postgres

Considered seriously; ruled for SQLite. Postgres would buy exact `numeric`
aggregation, transactional DDL swap, and one consolidated store — at the cost
of every deployment, dev checkout, and CI run needing a database service. For
a product whose pitch is install-in-minutes, the dependency-free deployment is
close to the whole pitch, and the gbasic repo's own opt-in Postgres test
gating shows what a required live server does to a hermetic suite. Exact money
is achieved without Postgres (§4). Containment: all staging access goes
through one `gdash_store` module (create/insert/swap/select), so a future
backend swap is one module's rewrite — this is discipline, not a pluggable
abstraction layer.

### Refresh

Refresh runs as a child process (`process.start`): profile + SQL + staging
path in; child fetches via the source module (synchronous `pg` is fine — the
child's whole job is to block), writes `<dataset>__staging.db`, exits. Parent
polls, and on success POSIX-renames over `<dataset>.db`, bumps the version
file, notifies. On failure or hang (`process.stop` + `force_after`) the old
file is untouched: **stale-but-coherent beats broken**; the UI shows
"data as of HH:MM". Credentials reach the child via 0600 temp file, never
argv. One SQLite file per dataset makes the swap a single `rename()`. Open
handles keep the old inode; readers reconnect on version notice.

Draft datasets refresh manually only. Published datasets follow their policy.

## 4. Money — exact by construction

gdash works with business finance; money accuracy is critical. Ruling:
**integer minor units**, the standard mechanism of exact financial computing.

- A dataset column declared `{ "type": "money", "scale": s }` materializes as
  INTEGER scaled by 10^s. Source strings with more decimals than `s` are
  rejected, not rounded.
- Per-column scale lives in a `_gdash_meta` table inside the dataset file.
- SUM/COUNT/MIN/MAX/GROUP BY over 64-bit integers are exact (~$92 quadrillion
  headroom at scale 2).
- Rendering divides through gBASIC's exact money type at the format layer
  (`"format": "currency"`).
- Division (averages, percentages) happens after exact sums; error is bounded
  to display rounding, or the division is done in gBASIC money.
- `pg` returns `numeric`/`bigint` as strings precisely to avoid float loss —
  the mapping consumes that directly.
- Named escape hatch if arbitrary-precision aggregation is ever required:
  SQLite's `decimal_sum` extension over TEXT decimals; shared future concern
  with the spreadsheet engine.

Undeclared columns map: integer-looking → INTEGER, numeric → REAL, else TEXT.

## 5. Server architecture

One gBASIC process using the PLAT-WEB `server` block: HTML shell, SVG
fragments, SSE, worker pool. Browser is a thin display; **all queries execute
server-side and clients receive only visual query results** — this is what
makes user-filtered dashboards over a shared dataset genuinely secure (the
trust boundary is the server, and the staged dataset never leaves it).

Workers are separate processes; there is **no shared in-memory state**.
Consequences, embraced:

- **Per-viewer interactivity rides request/response.** Parameter values live
  in the page and travel with each request; a param-change POST returns the
  re-rendered fragments for the visuals that bind it. The server holds no
  per-viewer session state for rendering.
- **SSE carries only global events** (`refresh`, `publish`), fanned out via
  the filesystem: each stream body polls the per-dashboard version file and
  emits on change. Any worker can observe independently; rename-swap
  guarantees a notified reader sees complete data.

**Known ceiling, named escape hatch:** every live SSE connection pins a
worker (PLAT-WEB stream economics). With SSE as a low-frequency notification
channel the pinned worker is nearly idle, and worker count is sized to max
concurrent open dashboard tabs plus request headroom in `server.json`. If
gdash outgrows this, the event-driven stream subsystem already named in the
PLAT-WEB design is the answer. Documented so the first big deployment doesn't
discover it.

Rendering: charts are produced server-side as SVG from
(result rows, channel mapping, dimensions). Per the Studio rule, that
function belongs to gBASIC's chart library with gdash as its first caller;
gdash couples to it only through mark and channel names. No JS chart library,
no build step; a small hand-written shim covers fetch/re-fetch, SSE listen,
and tooltips. Downsampling for huge-point visuals is just SQL in the visual
query.

## 6. Storage layout (FHS)

```
/etc/gdash/        server.json, connections.json (0600), users.json (0600)
/var/lib/gdash/    dashboards/<name>/{draft.json, current, snapshots/NNNN.json}
/var/cache/gdash/  <name>/{published,draft}/<dataset>.db + version
/var/log/gdash/    audit.log
/run/gdash/        pid, control socket
```

Precious state and disposable cache never share a directory: `/var/lib` is
the entire backup set; `/var/cache` may be deleted whenever the service is
stopped. All JSON stores carry `format`, write tmp-then-rename, validate with
`try_decode` + shape check on read.

**One resolver owns every path.** Subsystems ask for roles (`config_dir`,
`state_dir`, `cache_dir`, `log_dir`, `run_dir`); `--root <dir>` collapses all
roles under one directory for dev and hermetic tests; a Windows port would be
one function. Resolved roles logged at startup. `/etc/gdash/server.json` is
found-if-present; `--root` and flags override.

Deployment: dedicated `gdash` user under systemd;
`AmbientCapabilities=CAP_NET_BIND_SERVICE` for direct 80/443 (no nginx
required); `ProtectSystem=strict` + `ReadWritePaths` for sandboxing. Intranet
is the typical exposure: TLS recommended, not hard-required (internal CAs and
self-signed are the norm). Seamless updates come from PLAT-WEB's shipped
drain/inherited-socket/`pool_reload` machinery.

## 7. Draft and production

Immutable published snapshots + one mutable draft:

- Editing touches `draft.json` only. Publish copies draft →
  `snapshots/NNNN.json` and atomically repoints `current`. Rollback rewrites
  `current` alone. Snapshots are small text; keep all.
- Viewers resolve `current` at session open and **pin** that snapshot for the
  session; new versions arrive on next open or an explicit SSE reload nudge.
  No one sees a half-updated dashboard; publish never coordinates with live
  sessions.
- Version diff = text diff between snapshots ("what changed between the
  numbers the CFO saw Tuesday and today") — a headline feature for free.
- Self-contained records are what keep publish trivial; a draft edit cannot
  leak into production.

## 8. Identity, authorization, personalization

Three tiers, all resolved server-side; the record only ever sees identity
params and a group list:

1. **Local accounts** — base tier and bootstrap (first admin before any
   directory exists). Password hashing via the platform's `pbkdf2`/`scrypt`
   with per-password salt + algorithm metadata.
2. **LDAP(S) bind against AD** — covers most directory-using organizations;
   yields `memberOf` groups. Provider is a pluggable interface.
3. **OIDC/SAML** — deferred, exactly as pass-through was.

Sessions/login/CSRF follow the model in gbasic's site auth plan (server-side
sessions, HttpOnly SameSite cookie, CSRF tied to session). Candidate for
extraction into a shared stdlib component with gdash as first consumer and
the gbasic site as second — two consumers is the promotion bar.

**Authorization is coarse and per-dashboard:** the record names view groups
and edit groups; optional folder defaults later. `access: open` is a
**per-dashboard opt-in, never a server default** — a half-configured server
must fail closed. Provider configuration is necessarily server-level;
everything else rides in the record.

**Personalization** is the injected `user_*` params — a "my performance"
dashboard is an ordinary dashboard whose queries bind them. **Preview-as**
falls out free: in draft mode, an editor overrides the identity params with a
test identity; restricted to draft, restricted to editors, audit-logged.

Audit log: logins, publishes, preview-as, access denials.

## 9. Platform asks (tracked, not assumed)

- `sqlite.columns(db, sql)` — prepare-without-execute for channel validation.
  Small, in-module-style; completes the load-time red/green story.
- Session/auth stdlib extraction (§8) — a ruling for the gbasic repo, driven
  by two consumers.
- Everything else gdash needs shipped already: `server` block + `stream` +
  workers + TLS + drain/reload, `sqlite`, `pg`, `process.*`, `try_decode`,
  crypto KDFs, SVG-capable charts.

## 10. Deferred, by name

Pass-through visual queries; dataset sharing across dashboards; OIDC/SAML;
web-based designer GUI (v1 authoring is the record file itself); per-series
color overrides and theme editing; event-driven stream subsystem (platform);
exact decimal aggregation beyond minor units; Windows; additional source
connectors beyond Postgres (behind the same profile abstraction).
