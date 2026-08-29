# gdash — house rules for AI-assisted development

gdash is a dashboarding web application written in gBASIC. Read, in order:

1. `docs/gdash_design.md` — the architecture rulings and their reasons.
   Authoritative. If implementation contradicts it, that contradiction is a
   finding to report, never a silent edit to either.
2. `docs/gdash_development_plan.md` — the phase roadmap.
3. The current phase brief (for GDASH-0: `docs/gdash0_spike_brief.md`) — the
   only scope that is in play. A brief may narrow the plan; it never widens.

## Method

- Phases open with their step-0 verifications. If a verification fails, stop
  and report — do not design around it.
- Tests first where a behavior can be pinned. The suite is hermetic: it runs
  under `--root` in a temp dir, requires no network, no live database, and no
  display. Anything needing a live service is a separate opt-in runner gated
  on an environment variable (convention: `GDASH_POSTGRES_TEST=1`).
- Every test run ends with a scratch-clean assertion.
- Implement, test, commit locally with focused commits. Stop at the review
  boundary and write a report. Never push.
- Deliberately-not-built items go in the report and the brief's DONE note,
  not into silently widened scope.

## Environment

- The gBASIC interpreter is built from the sibling repo
  (`~/development/gbasic`); the binary path comes from `GDASH_GBASIC` or
  config. Never modify the gbasic repo from here. Platform gaps or defects
  discovered while building gdash are findings for the report (and candidates
  for gbasic's DOGFOOD.md, filed only through that repo's own process).
- All paths go through the resolver (`--root` for dev/tests, FHS when
  installed). No path literal outside the resolver module.
- Credentials never appear in dashboard records, argv, commits, or test
  fixtures. Test profiles use obviously-fake values.

## Design invariants worth restating

- Params appear only in visual queries, never dataset queries.
- The dependency graph is derived from `:name` bindings in SQL text, never
  declared.
- Refresh is stale-but-coherent: a failed refresh leaves the old dataset file
  untouched. Swap is a single POSIX rename; version file bumps after.
- Money columns materialize as INTEGER minor units with per-column scale in
  `_gdash_meta`; excess decimals are rejected, not rounded.
- Workers share no in-memory state: per-viewer interactivity rides
  request/response; SSE carries only global events observed via the
  filesystem.
- All staging-store access goes through the `gdash_store` module.
- `access: open` is per-dashboard opt-in; everything fails closed.
