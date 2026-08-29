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
lives in the names.

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

## GDASH-6 — Chart vocabulary and rendering depth

Grow the mark set and channel depth against real dashboards: legends, axes
formatting, multi-series behavior, tooips/click-to-publish-parameter in the
shim, downsampling patterns documented as SQL. Per the Studio rule, general
chart capability lands in gBASIC's chart library with gdash as first caller;
gdash-side work is encoding → library-call translation and the theme layer
(server-level theme file; per-series color override as the first knob if
demanded).

## GDASH-7 — Deployment and operations

systemd unit (`CAP_NET_BIND_SERVICE`, `ProtectSystem=strict`,
`ReadWritePaths`), FHS install target + `--root` parity tests, TLS
configuration surface over PLAT-WEB's shipped TLS, drain/`pool_reload`
integration for seamless updates, worker-sizing documentation (the SSE
worker-pinning ceiling stated plainly, per the PLAT-WEB doc's own
instruction), backup/restore doc (one directory), admin CLI for
create/publish/rollback/user management as needed. This is the
"stand it up in an afternoon" phase; its deliverable is partly documentation.

## Unscheduled, deliberately

Pass-through queries; dataset sharing; OIDC/SAML; web designer GUI;
additional source connectors (SQL Server is the likely first, given demand);
event-driven streams (platform); exact decimal aggregation beyond minor
units; Windows. Each waits for a phase's findings or a real deployment to
justify it — the plan's job is to name them so deferral stays a decision.

## Cross-repo items

Tracked here, ruled in the gbasic repo: `sqlite.columns(db, sql)`;
session/auth stdlib extraction; any chart-library growth GDASH-6 drives;
DOGFOOD.md entries for anything gdash's use of the platform surfaces.
