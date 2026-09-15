# gdash — Development Plan

**Method:** one phase per Claude Code execution, each with its own brief
written at execution time (this plan is the roadmap, not the briefs). Each
phase: tests-first where behavior can be pinned, implemented + tested +
committed locally, stop at a review boundary, report before push. Step-0
verification of premises opens any phase whose ground hasn't been proven.
Scope statements below are intentionally one paragraph; a phase brief may
narrow them, never silently widen.

Later phases are sketched more loosely on purpose — earlier findings are
expected to reshape them, as they did on Studio. Renumber freely; identity
lives in the names. GDASH-6 is an example of that: it was not in the original
roadmap and was inserted after GDASH-5, on the judgement that no deployment
was near and that quality mattered more than pace.

**Numbering note.** Briefs written before GDASH-6 was inserted use the old
numbers, and they are left as written rather than edited: chart vocabulary was
GDASH-6 and is now **GDASH-7**; deployment and operations was GDASH-7 and is
now **GDASH-8**. So a forward pointer to "GDASH-7" in `gdash1_brief.md` through
`gdash5_brief.md` means deployment, not charts.

## GDASH-0 — Vertical spike  *(brief exists: gdash0_spike_brief.md)*

Prove the spine end to end on shipped platform pieces: one record →
validation → refresh child (pg → SQLite, minor-unit money) → rename-swap +
version bump → visual queries → SVG fragments → one slicer round-trip → SSE
refresh notification. Hermetic suite via the fixture-source seam; live-pg
runner opt-in. Findings gate everything after.

## GDASH-1 — Record format completion

Everything the format promises that the spike stubbed: tabs, `table` mark
with per-column formats, `value`/`bar`/`line` marks with `series`, full
`space`/`gap`/`weight` semantics with the dead-`space` warning, format map
(`currency` at minimum), the full validation catalog with pinned refusal
messages as goldens. Decide `sqlite.columns` here: if the platform item is
approved and lands, wire channel validation; otherwise pin the
first-refresh fallback behavior. Reference record + format doc versioned
`format: 1` for real.

## GDASH-2 — Refresh engine

From one manual refresh to the real thing: interval and on-open policies,
per-dataset scheduling off the server's timer, multiple datasets per
dashboard with ATTACH-based visual queries, failure surfacing ("data as of",
error state per dataset, audit-logged), staging sweep for crash residue,
draft-vs-published data directories with draft-manual-only enforced, the
(source, query) content-hash dedupe if it proves worth it. The `gdash_store`
module boundary hardens here.

## GDASH-3 — Draft, publish, snapshots

The §7 lifecycle: snapshot write + atomic `current` repoint, rollback,
session pinning of snapshots, SSE reload nudge, snapshot diff surfaced (even
if only as a CLI/endpoint returning the two texts), publish audit events.
Draft editing itself is still file editing; no designer UI.

## GDASH-4 — Sessions, local auth, access enforcement

Local accounts with KDF-hashed passwords, login/logout, server-side sessions,
HttpOnly SameSite cookie, CSRF on state-changing routes, per-dashboard
view/edit group enforcement, `access: open` opt-in with fail-closed default,
bootstrap first-admin flow, audit events. Open the shared-session-stdlib
question with the gbasic repo before building: extract if approved, build
gdash-local with extraction in mind if not.

## GDASH-5 — Directory auth and personalization

LDAP(S) bind provider behind the provider interface, group resolution via
`memberOf`, `user_*` param injection for real, preview-as (draft-only,
editor-only, audited). Connection profile story finalized for auth providers
(server-level config, 0600).

## GDASH-6 — Hardening  *(inserted after GDASH-5; renumbers what follows)*

No new capability. Close the gap between what is designed and what is
observed, before the chart phase builds more on top of it. Multi-worker
verification of design §5's shared-nothing claim (step-0, and the first time
it has ever been executed); hermetic in-process tests for `gdash_app` — 1083
lines holding every authorization decision, covered until now only by `curl`
and substring matching; a seam under the LDAP wire so the provider's policy
runs in the default suite rather than only when a container happens to be up;
concurrency tests for the refresh lock and the publish swap; and an
end-to-end assertion style that cannot pass for the wrong reason. The
deliverable is confidence, and its measure is coverage that survives an
adversary rather than a happy path.

## GDASH-7 — Chart vocabulary and rendering depth

Grow the mark set and channel depth against real dashboards: legends, axes
formatting, multi-series behavior, tooips/click-to-publish-parameter in the
shim, downsampling patterns documented as SQL. Per the Studio rule, general
chart capability lands in gBASIC's chart library with gdash as first caller;
gdash-side work is encoding → library-call translation and the theme layer
(server-level theme file; per-series color override as the first knob if
demanded).

## GDASH-8 — Deployment and operations

systemd unit (`CAP_NET_BIND_SERVICE`, `ProtectSystem=strict`,
`ReadWritePaths`), FHS install target + `--root` parity tests, TLS
configuration surface over PLAT-WEB's shipped TLS, drain/`pool_reload`
integration for seamless updates, worker-sizing documentation (the SSE
worker-pinning ceiling stated plainly, per the PLAT-WEB doc's own
instruction — the ceiling itself was removed in GDASH-11 and the sizing
section rewritten around what a request actually costs), backup/restore doc
(one directory), admin CLI for
create/publish/rollback/user management as needed. This is the
"stand it up in an afternoon" phase; its deliverable is partly documentation.

## GDASH-9 — ODBC import  *(brief: gdash9_brief.md)*

Scheduled out of *Unscheduled, deliberately* — "additional source connectors" —
by the maintainer, with the shape settled first: **gdash keeps one store of its
own and imports from many origins.** ODBC is a driver manager, so one connector
reaches SQL Server, MySQL, Oracle and the rest without a connector each.

Complete. Its opt-in runner is the cheapest of the live ones, because the SQLite
ODBC driver reads a file and needs no service.

## GDASH-10 — Chart follow-through  *(brief: gdash10_brief.md)*

Narrowed GDASH-7's deferred scope, including the two limits its DONE note had
recorded as waiting on the platform. Complete, and verified against the
**installed** chart library rather than the working tree — which is the habit
that GDASH-12 step 0 later needed and GDASH-13 needed again.

## GDASH-11 — The worker a viewer holds

**Inserted ahead of deployment**, because gdash as shipped served one fewer
viewer than it had workers and the default worker count is one: opening a
single dashboard made the server answer nothing else. The page held an SSE
stream whose handler looped in `sleep()` and never returned, and a handler
that never returns is a worker that never comes back. (Not a property of
`stream` — corrected in G11-13.) The browser now polls `/d/{name}/version`
for the same two facts the stream carried — the dataset version and the publish pointer — read from the
filesystem exactly as before, so design §5's shared-nothing principle is
untouched and only the process doing the waiting changed.

Delivered with a ceiling suite that runs at the DEFAULT worker count, and the
first test anywhere that executes the page's own JavaScript.

**Design §5's sentence names SSE as the carrier and is now wrong in its
mechanism** — the correction belongs to the maintainer, not to a phase.

## GDASH-12 — Natural-language questions, over a dashboard's own data

**gBASIC shipped `stdlib/nlq.bas`**, which performs no I/O: it grounds a
question, builds a prompt, checks what comes back, and settles an answer
against rows somebody else fetched. gdash is its first consumer, and everything
the library leaves out — the catalog, the vocabulary, the model call, running
the SQL, and knowing that an integer is cents — is gdash's.

A question produces a **draft visual**, not an answer: the generated SQL, what
its numbers mean in the columns' own units, the `data as of` it read, and a
real render of what promotion would produce. A person promotes it, and it is
then versioned, diffed and audited like every other visual. A wrong query is
caught while it is still a draft, by somebody who can read SQL.

Step 0 measured why the unit note is the whole point: *"how many orders were
over 1000 dollars?"* against a column holding cents produced valid SQL, zero
reported problems, and an answer wrong by a factor of a hundred. gdash does not
refuse it — someone may genuinely mean ten dollars — it says what the number
means.

Delivered with the shadowing refusal (a stray `.bas` in gdash's module
directory would otherwise replace `crypto`), every ATTACH made read-only, and a
question corpus scoring 15/15 grounded and 5/5 refused with no model at all.

**The design document says nothing about asking questions in English.** Three
decisions in the DONE note are the maintainer's to confirm or overrule.

## GDASH-13 — Money that is not dollars

**Unplanned, and found by building a fixture.** Every money figure gdash had
rendered in thirteen phases was US dollars at scale 2, because every fixture
was. A banking-shaped dashboard — USD at scale 2 beside JPY at scale 0 in one
dataset, rates at scale 4, negative balances — broke four things, three of them
silently.

The worst: a table rendered every money column at one dataset-wide scale, so
every yen figure came out a hundred times small in a table that looked entirely
normal, and a real balance of ¥12 rendered as ¥0. The oldest: `_symbol` was
written as the UTF-8 *bytes* of `¥` handed to a function that takes
*codepoints*, so every non-dollar figure had been mojibake since GDASH-1 — and
the test asserted the bug. The third put the money formatter and the
cross-dataset join in each other's way. The fourth was GDASH-12's own promotion
producing a visual that could not render.

Scale is now per column, as `_gdash_meta` has recorded it all along, and what is
genuinely ambiguous refuses rather than guessing.
`dashboards/treasury/draft.json` is permanent and renders over HTTP on every
run.

Also absorbed the platform's answers to GDASH-12's report: the units channel now
reaches the model, `plan` refuses a question that grounds nothing, and the
library-shadowing rule narrowed — which turned `gdash_shadow` from a guard into
a guard with a false refusal in it, caught by the suite's own premise assertion.

## Multi-tenancy — GDASH-14 onward

Design: `gdash_saas_design.md`. Assessment and measurements:
`gdash_saas_assessment.md`. **Single-tenant remains a first-class deployment
throughout** — it is what a deployment with no tenant registry is.

The ordering below is not arbitrary. GDASH-14 comes first because the whole
plan now leans on restarts being reliable, and the restart mechanism has never
been executed. GDASH-16 comes before GDASH-17 because a tenant that can spend
money without a ceiling should not be given the ability to spend money.

### GDASH-14 — The units, actually started  *(G8-7, now blocking)*

Not new work. `systemd-analyze verify` has accepted every directive since
GDASH-8 and **no `systemctl start` has ever happened** — operations §10 says so
in as many words. Under the no-failover ruling the operating model is "we
restart things and that is fine", which makes an untested restart the weakest
link in everything that follows.

Start the units. Stop them. Restart under load and confirm the drain promise
(operations §7, tested in `run_drain.sh`) holds through a real `systemctl
restart` rather than a bare SIGTERM. Reboot the host and confirm what comes
back. Then write down what a `gdash-scheduler@tenant` template unit looks like,
because GDASH-15 needs one.

Small, overdue, and the prerequisite for treating downtime as cheap.

### GDASH-15 — Tenant as a root

The core, and small **because of decisions already made**: the resolver exists,
`_root_of(req)` already takes the request, and there is no cross-request state
to segregate.

- The registry, and `_root_of` resolving Host → tenant → root.
- Unknown host refuses. Suspended refuses. No default tenant in any path.
- Tenant-id validation, and `real_path` containment on a separator boundary.
- `gdash tenant create|list|suspend|resume|delete`, registry entry written last.
- A format stamp per tenant.
- `--tenant` on every CLI verb that takes `--root`.

**Step 0 measures before it designs:** the registry lookup's cost per request,
and whether two servers' worth of tenants on one box changes anything about the
numbers in the assessment.

**The verification is a two-tenant suite**, in the shape of `run_workers.sh`:
two roots, one server, and assertions that a session from A is anonymous at B,
that a dashboard name known to A is a 404 at B, that `..` and its relatives are
refused as tenant ids and as dashboard names, that an ATTACH never crosses
roots, and that an unknown Host is refused. **Isolation that is not executed on
every run is isolation nobody can vouch for a year from now.**

### GDASH-16 — Limits

Nothing here exists, and none of it is conceptually hard; it is simply absent.
It comes before opening the door because a limit added after the first incident
is a limit that was needed before it.

- Per-tenant disk quota on `cache/`, refusing the refresh and leaving the old
  dataset intact — which is the stale-but-coherent rule already.
- A cap on concurrent refresh children, global and per tenant. Per-tenant
  schedulers removed the accidental serialization a single blocking scheduler
  provided; this is what replaces it deliberately.
- A **measured** dataset-size ceiling. A refresh holds the whole result set in
  memory, so the ceiling is the child's RAM. Measure it, document the number,
  and refuse above it rather than dying.
- A per-tenant model budget with a refusal when exhausted. This is the item most
  likely to be discovered by a bill rather than by a test.

### GDASH-17 — Operating many tenants

- `gdash tenant export` / `import`: the backup story, the move-between-servers
  story and the deletion story are the same directory operation, and want to be
  exercised before they are needed rather than written during an outage.
- Per-tenant backup and a **tested** restore, extending the FHS suite rather
  than duplicating it.
- An operator-side event stream — sign-ins, refresh failures, spend — which is
  what tolerating downtime obliges, because a human is now the failover.
- `gdash tenant migrate --all`, reading the format stamp.
- A tenant-level policy gate on `access: open`, defaulting to forbidden.

### GDASH-18 — The onboarding surface  *(shape only; not scheduled)*

An admin endpoint in front of the same code the CLI calls, for a remote
onboarding service to drive. Named here so that "the CLI is the API" stays a
decision rather than a constraint discovered later. The onboarding site itself
is a separate product and is not gdash's to build.

---

## Still open, carried forward

Every item below was deferred deliberately and is recorded so that deferral
stays a decision. Nothing here is forgotten work.

### Blocked on something outside gdash

- **TLS.** gdash refuses to start with `GDASH_TLS_CERT`/`KEY` set rather than
  serve cleartext, because the platform accepts the pair and then serves in the
  clear (`gdash8_platform_report_tls.md`). Terminating at a proxy is the
  documented answer, and under the SaaS design the proxy exists anyway — so this
  is no longer on the critical path, and the report stays open.
- **The NLQ answer tier.** Recall and refusal rate through a real model, against
  a real dashboard's estate. The runner is built and gated on
  `GDASH_NLQ_TEST=1`; it needs a key and a decision to spend it. The grounding
  tier (15/15 grounded, 5/5 refused) is measured and in the suite.

### Owed to the maintainer — design rulings, never made silently

Each is a place where implementation and `gdash_design.md` have diverged, or
where the design document is silent on something now built. A phase may report
these; it may not edit either side to agree.

- **§5's SSE sentence** names a carrier gdash no longer uses. Wrong in
  mechanism, right in principle (GDASH-11).
- **Whether publish should carry the draft's data across** (G11-11). §7
  authorises copying the record and is silent on the data, so a published
  dashboard is empty until something refreshes it. Three defensible answers are
  written out in the findings.
- **§8's `memberOf` sentence**, `password_hash` naming, and local-provider-first.
- **§4's money headroom and the render path; §2's content-hash.**
- **The design document says nothing about asking questions in English**
  (GDASH-12) — the largest of these. Three decisions were made against this
  session's arguments rather than a ruling: that a question edits the draft and
  so the draft's edit groups govern it; that the draft rides the session between
  asking and promoting; that promotion places the visual on the first tab.
- **§4 is silent on what the renderer does when one result set spans two
  scales** (GDASH-13). It now refuses. If the intended answer was a per-visual
  scale declaration, that is a record-format change. The same ruling covers
  G13-5, where "the primary wins a column-name collision" was reversed on the
  grounds that it can only be silently wrong.
- **Multi-tenancy itself**: `gdash_saas_design.md` §9 lists the four sections
  that would need a sentence.

### Deferred features, with the reason attached

- **An NLQ answer cache.** `nlq` supplies `plan.key`. Promotion stores the SQL
  rather than the question, so a dashboard never re-asks; only a person
  re-asking the same words in the drafting UI would benefit.
- **Follow-up questions and chat history.** "And by month?" needs conversation
  state, which is a different design with a different set of failures.
- **Choosing between ambiguous candidates in the UI.** The refusal carries them
  and both surfaces print them; neither offers a click.
- **A model-side retry.** Retrying automatically spends money on a guess about
  why the first attempt failed.
- **Per-row currency.** Real core banking stores `amount` beside
  `currency_code` and lets scale vary by row; gdash's model is one scale per
  column and cannot express it. Naming the limitation was GDASH-13's
  deliverable. Currency conversion is deferred with it.
- **A configurable poll interval**, and a cache to make the version poll cheaper
  than its measured 28 ms.
- **Symbols beyond the four.** `CHF 1,234.00` is correct and unambiguous for the
  other 174 ISO 4217 codes.

## Unscheduled, deliberately

Pass-through queries; dataset sharing (and cross-tenant anything, which the
multi-tenancy design rules out by name); OIDC/SAML; web designer GUI;
additional source connectors (SQL Server is the likely first, given demand);
cross-worker reach for parked streams (platform —
asked for, answered at gbasic `e56daa0`, and **not planned**: a broadcast to
every viewer means `workers: 1`, which gdash cannot take, so polling is the
permanent answer here rather than a stopgap); exact decimal aggregation beyond minor
units; Windows. Each waits for a phase's findings or a real deployment to
justify it — the plan's job is to name them so deferral stays a decision.

## Cross-repo items

Tracked here, ruled in the gbasic repo: `sqlite.columns(db, sql)`;
session/auth stdlib extraction; any chart-library growth GDASH-6 drives;
DOGFOOD.md entries for anything gdash's use of the platform surfaces.
