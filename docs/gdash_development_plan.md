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

## Unscheduled, deliberately

Pass-through queries; dataset sharing; OIDC/SAML; web designer GUI;
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
