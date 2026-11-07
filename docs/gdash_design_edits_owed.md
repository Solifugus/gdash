# Design edits owed to the maintainer

`gdash_design.md` is authoritative, and a phase may report a contradiction but
never edit either side to agree (CLAUDE.md). This is the accumulated report,
with the edit written out so applying it is mechanical.

**Seven corrections** — the document is wrong or stale, no decision required.
Quoted text is verbatim from `gdash_design.md` at the tree of 2026-09-15; line
numbers are a hint, not an anchor.

**Four rulings** — listed at the end. Those need a decision before there is a
sentence to write.

---

## 1. §5 — SSE is named as the carrier, and the ceiling is explained wrongly

**Two separate errors in one section**, and the second is the more important
because it is a *reason* rather than a *mechanism*.

### 1a. The carrier (line ~172)

> - **SSE carries only global events** (`refresh`, `publish`), fanned out via
>   the filesystem: each stream body polls the per-dashboard version file and
>   emits on change. Any worker can observe independently; rename-swap
>   guarantees a notified reader sees complete data.

**Replace with:**

> - **Global events travel by polling** (`refresh`, `publish`), observed
>   through the filesystem: the browser polls `/d/{name}/version`, which
>   returns the per-dashboard version file and the publish pointer. Any worker
>   can answer independently; rename-swap guarantees a notified reader sees
>   complete data.

The principle — the truth lives on disk, not in any worker's memory — is
unchanged and is the load-bearing half. Only the carrier moved (GDASH-11).

### 1b. The "known ceiling" paragraph (lines ~177–183)

> **Known ceiling, named escape hatch:** every live SSE connection pins a
> worker (PLAT-WEB stream economics). With SSE as a low-frequency notification
> channel the pinned worker is nearly idle, and worker count is sized to max
> concurrent open dashboard tabs plus request headroom in `server.json`. If
> gdash outgrows this, the event-driven stream subsystem already named in the
> PLAT-WEB design is the answer. Documented so the first big deployment doesn't
> discover it.

**This paragraph should be deleted, not corrected.** Its premise is false: a
stream handler that *returns* parks the connection and frees its worker, and
always could — gdash's own handler looped in `sleep()`, which was gdash's bug
and not a platform ceiling (G11-13, confirmed by the gbasic session at
`e69896`/`e56daa0`).

**Replace with:**

> **Why polling rather than a held stream.** A parked stream belongs to the
> worker that accepted it, and cross-worker reach did not ship and is not
> planned — so a notification that must reach *every* viewer would mean
> `workers: 1`, and worker count is what stops a burst of page loads queueing.
> Polling reaches every viewer at every worker count. Measured: a poll costs
> ~28 ms, a page ~57 ms; thirty viewers on one worker, zero failed polls.

### 1c. Two incidental mentions

Line ~160 lists `SSE` among what the `server` block produces, and line ~189
says the shim covers "fetch/re-fetch, SSE listen, and tooltips". Both should
drop `SSE`; the shim now covers fetch/re-fetch, **version polling**, and
tooltips.

---

## 2. §8 — password hashing names the wrong primitives (line ~243)

> Password hashing via the platform's `pbkdf2`/`scrypt` with per-password salt
> + algorithm metadata.

**Replace with:**

> Password hashing via the platform's `password_hash` / `password_verify`
> (yescrypt; salt and parameters embedded in the hash, so one field stores it).
> `password_hash_cost()` reports the measured per-hash cost on the machine in
> front of you — ~12 ms here — which is how a deployment states its KDF posture
> rather than assuming one.

Accepted by the platform review at the time; the sentence simply predates it.

---

## 3. §8 — LDAP group resolution is not `memberOf` (line ~245)

> 2. **LDAP(S) bind against AD** — covers most directory-using organizations;
>    yields `memberOf` groups. Provider is a pluggable interface.

**Replace with:**

> 2. **LDAP(S) bind** — covers most directory-using organizations. **Group
>    resolution is configured, not assumed:** stock OpenLDAP does not populate
>    `memberOf` (the overlay is off by default), so the provider supports
>    `memberof`, a `member=`-style group search, and a fixed group list, chosen
>    per deployment. Provider is a pluggable interface.

G5-4. Written as-is, the sentence describes Active Directory and misdescribes
the directory most likely to be met in testing.

---

## 4. §8 — the provider list should say local is consulted first, and why (line ~242)

Add to the tier list, after item 3:

> **Local accounts are consulted first, always.** A directory that is down, or
> an `auth.json` that does not parse, must not lock out the operator who has to
> fix it. The cost is one hash on a directory login; the alternative is a
> deployment that can be locked out of itself by its own configuration.

---

## 5. §4 — the money headroom figure is wrong by three orders of magnitude (line ~143)

> - SUM/COUNT/MIN/MAX/GROUP BY over 64-bit integers are exact (~$92 quadrillion
>   headroom at scale 2).

**Severity: this is the one that matters.** SQLite's own arithmetic is exact
int64, but gBASIC numbers are IEEE-754 doubles, so any integer above 2^53 read
into gBASIC is silently rounded — and the limit binds on **every individual
value and every aggregate result**, not just on column totals. Real headroom at
scale 2 was 2^53 minor units ≈ **$90.07 trillion** (F1).

Since GDASH-4 the rendering path goes through the platform money type, which is
int64 at the currency's storage scale (exponent + 4 guard digits), so the
practical ceiling is now **the currency's own exact range** and gdash refuses
above it rather than falling back to a second formatting path.

**Replace with:**

> - SUM/COUNT/MIN/MAX/GROUP BY are exact in SQLite, which aggregates INTEGER as
>   int64. **The binding is the lossy hop:** gBASIC numbers are doubles, so
>   minor units cross from SQLite as decimal **text** and never as numbers —
>   above 2^53 a value read as a number is silently rounded, and the limit binds
>   on each value and each aggregate, not only on totals.
> - Rendering is bounded by the currency's own exact range (int64 at exponent+4
>   guard digits): USD stops at $9,223,372,036,854.77. Beyond it gdash
>   **refuses to render** and says so, distinguishing rendering from storage —
>   the stored data is untouched.

---

## 6. §4 — the render path sentence invites the division that loses the cent (line ~145)

> - Rendering divides through gBASIC's exact money type at the format layer
>   (`"format": "currency"`).

"Divides through" is the exact operation that must not happen in gBASIC.

**Replace with:**

> - Rendering builds a money value **from decimal text** at the format layer
>   (`"format": "currency"`), never from `minor / 10^s` — that division is a
>   double hop and loses the cent. Scale is per column (`_gdash_meta`); where a
>   result column's scale cannot be resolved, the visual refuses rather than
>   assuming one.

The second sentence also closes ruling **C** below, if you take that reading.

---

## 7. §2 — the content-hash sentence describes something not built (line ~38)

> Datasets are private to their record; if two dashboards fetch the same
> thing, the server MAY dedupe refresh work internally by content-hashing
> (source, query) — invisible to the format.

Deduping by `(source, query)` means sharing one fetch between dashboards. That
needs a cross-dashboard registry, and first-class dataset sharing is deferred by
name in §10 — so this is not built and is not planned (G2-10).

What *is* built hashes the fetched **result**: a refresh whose result matches
the stored hash discards its staging file, skips the swap, and does not bump the
version. It saves a rename and a notification, not a fetch — and it earns its
place because every open tab reloads on a version bump, so a five-minute
interval over static data was reloading every viewer twelve times an hour to
show them identical numbers.

**Replace with:**

> Datasets are private to their record. A refresh **content-hashes its result**
> and, when nothing has changed, discards the staging file and leaves the
> version unbumped — which matters because a version bump reloads every open
> tab. Sharing a *fetch* between two dashboards that ask for the same thing is a
> different mechanism, and is deferred with first-class dataset sharing.

---

# The four rulings

No sentence is proposed for these, because each needs a decision first.

**A. Does publish carry the draft's data across?** (§7, G11-11)
Three defensible readings — carry it, refresh it, or leave it. gdash currently
does the third *out loud*: publish reports how many datasets are empty and names
the command that fills them, which is safe under all three. The findings write
out the case for each.

**B. Where does natural-language querying sit?** (GDASH-12)
The document does not mention it. Three decisions were made against a phase
brief rather than a ruling: that asking edits the draft and so the draft's edit
groups govern it; that the draft rides the session between asking and promoting;
that promotion places the visual on the first tab.

**C. What does the renderer do when one result set spans two money scales?**
(§4, GDASH-13) It now refuses, naming the column. The alternative is a
per-visual scale declaration, which is a record-format change. The same ruling
covers **G13-5**, where "the primary wins a column-name collision" was reversed
on the grounds that it can only ever be silently wrong.

**D. Multi-tenancy.** `gdash_saas_design.md` §9 names the four sections that
would need a sentence: §6 (a deployment may hold many roots), §8 (the tenant
boundary, and `access: open` in a multi-tenant deployment), §5 (that
shared-nothing is what makes tenancy safe, said where it is stated), §3 (the
refresh-concurrency limit, once it has a shape).

---

## One more, arriving with the SaaS work

§6's TLS paragraph reads as a limitation. Under `gdash_saas_design.md` the proxy
— nginx — is the intended architecture rather than a workaround: it terminates
TLS, routes tenants by subdomain, and holds the wildcard certificate. Worth a
sentence saying so, so the next reader does not treat "gdash refuses to serve
TLS" as a gap to be closed.

# Arriving with GDASH-20: the staging store on G-SQL

**Applied 2026-11-07** on the maintainer's approval, G20-a to G20-g, with
three more stale phrases the list had missed: §4's opening ruling, "rename-swap"
in §5, and §10's deferred "exact decimal aggregation beyond minor units". Edits
5 and 6 above are superseded by G20-c.

Every ruling behind these is in `gsql_migration_plan.md` §3 (D1–D5, D4a). The
code follows them, so the design document is now the thing that is out of
date. Each entry below quotes the current text and gives its replacement.

## G20-a. §3 — the two tiers, and the staging store

> **Datasets** materialize source query results into local SQLite files

becomes

> **Datasets** materialize source query results into tables in a local G-SQL
> database, one per dashboard and stage

The sentence "*Two dialects* (source SQL + SQLite SQL) is the accepted honest
cost; … a visual query ATTACHes and joins" keeps its point and changes its
mechanism: "two datasets from different sources land in the same database as
two tables; a visual query joins them by name."

The section *Staging store: SQLite, and why not Postgres* is replaced, not
amended. Its reasoning survives: no service to run, an install in an
afternoon, a hermetic suite. The ruling changes. Proposed text:

> **Staging store: G-SQL.** gBASIC's own database, part of the interpreter, so
> there is still nothing to install and the suite stays hermetic. Its values
> are gBASIC values, so money and integers past 2^53 cross no boundary (§4).
> One database per (dashboard, stage), each dataset a table in it. A
> dashboard's SQL can therefore name its own datasets and nothing else: the
> wall between dashboards is the directory, as the wall between tenants is.
> All staging access still goes through `gdash_store`. It went from SQLite to
> G-SQL as one module's rewrite, as this paragraph promised.

## G20-b. §3 Refresh — the swap

> writes `<dataset>__staging.db`, exits. Parent polls, and on success
> POSIX-renames over `<dataset>.db`, bumps the version file, notifies. … One
> SQLite file per dataset makes the swap a single `rename()`. Open handles keep
> the old inode; readers reconnect on version notice.

becomes

> writes the `<dataset>__staging` table, exits. Parent polls, and on success
> drops the live table and renames the staging one over it **in one
> transaction**, bumps the version file, notifies. A reader inside a read
> transaction keeps the snapshot it began with until it finishes; the next
> read sees the new table.

## G20-c. §4 — money

This replaces the stored-form bullets, and overtakes edits 5 and 6 above:

> - A dataset column declared `{ "type": "money", "scale": s, "currency": c }`
>   materializes as `money(c)`: gBASIC's money, exact, with its currency.
> - `s` is the **display** scale. Values are stored exactly as the source gave
>   them and rounded half-even only when a person is shown them. Only a value
>   the currency cannot hold (more places than its minor unit plus four guard
>   digits) is refused, and it fails the refresh.
> - Aggregation is exact as money, up to the currency's range (about USD 9.2
>   trillion); a sum past it raises warning 2112 and fails its visual.
> - Display scale and currency per column live in `_gdash_meta`.

The `decimal_sum` escape hatch goes, because nothing is TEXT any more.
"Undeclared columns map: integer-looking → INTEGER, numeric → REAL, else
TEXT" becomes "→ `integer`, `number`, `string` (gBASIC kinds)".

## G20-d. §6 — storage layout

> /var/cache/gdash/  <name>/{published,draft}/<dataset>.db + version

becomes

> /var/cache/gdash/  <name>/{published,draft}/data.gsql + version + state

## G20-e. §9 — platform asks

`sqlite.columns(db, sql)` becomes describe-without-execute on G-SQL
(`gdash20_platform_ask_gsql.md` A2). Two more join the list: the owner socket
under `PrivateTmp` (A1, which blocks deployment) and the dialect gaps (A5).

## G20-f. §2 — params

> **Params** declare name + default.

becomes

> **Params** declare name + default, and optionally a `type` (`string`,
> `integer`, `number`, `date`, `money`). A value is converted to its type when
> the request arrives and refused by name if it does not convert.

## G20-g. CLAUDE.md, *Design invariants worth restating*

That file is the maintainer's to edit, so the change is written here.

> - Refresh is stale-but-coherent: a failed refresh leaves the old dataset file
>   untouched. Swap is a single POSIX rename; version file bumps after.
> - Money columns materialize as INTEGER minor units with per-column scale in
>   `_gdash_meta`; excess decimals are rejected, not rounded.

becomes

> - Refresh is stale-but-coherent: a failed refresh leaves the old dataset
>   table untouched. Swap is one transaction (drop live, rename staging);
>   version file bumps after.
> - Money columns are `money(<currency>)`, stored exactly; `scale` is the
>   display scale, rounded half-even only for a person. A value the currency
>   cannot hold is rejected, not rounded.
