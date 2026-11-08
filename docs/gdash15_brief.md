# GDASH-15 — Tenant as a root

**Status:** built, at the review boundary (2026-11-08).
**Authority:** `gdash_design.md` outranks this brief; the multi-tenancy design
it implements is `gdash_saas_design.md`.

## Why this phase exists

A deployment serves many organisations once a tenant is a root: one directory
holding the five roles, sharing nothing. The wall is the filesystem, and one
function decides which root a request belongs to. The resolver, the `--root`
layout and the rule that workers keep no state already existed. This phase
adds the registry, the resolution, and a suite that executes the wall on every
run.

## Step 0 — measured before designing

- **Registry lookup cost per request.** Workers keep no state, so the
  registry is read on every request.
  - One tenant: **0.013 ms**.
  - 500 tenants, worst case (the last entry; 48 KB of JSON): **1.2 ms**.

  A page renders in about 57 ms, so even 500 tenants adds about 2%. A
  per-worker cache would be the cross-request state design §8.1 warns
  against, and is not built.
- **`real_path` canonicalises `..`** and is the primitive containment rests
  on. On a path that does not exist yet it answers a non-string rather than
  raising; `root_of` treats that as "not yet created" (G15-1).
- **The server's cost does not grow with tenant count.** It holds nothing
  between requests. What does grow is G-SQL owner processes, one per open
  dashboard and stage across all tenants. Each starts in about 20 ms and stops
  after its linger (GDASH-20). The assessment's numbers otherwise stand.

## Decisions made in building it

- **A tenant's root is derived, not stored:** `<base>/<id>`. The design's
  example gives each tenant a free-form `root`. A derived root, checked with
  `real_path` against the canonical base on a separator boundary, is one less
  path an edit can point anywhere, and it also refuses a tenant directory
  that is a symlink out of the base.
- **The refusals:**
  - an unknown host or a missing `Host` gets **404** "no such site";
  - a suspended tenant gets **403**;
  - an invalid registry gets **503** for every host.

  None of them falls back to the deployment's own root.
- **`tenant create` does not make the first admin.** `gdash --tenant <id> user
  add <name> --admin` does, with the password read from stdin as it always is.
  Making the admin inside `create` would have meant a second password path.
- **`tenant delete` removes the registry entry and keeps the directory.** The
  tenant is unreachable at once, and its data is never removed by gdash; the
  command prints the path. Recreating an entry is easy, and a tenant's data
  is not.
- **The scheduler per tenant** is a pair of systemd template units,
  `gdash-scheduler@<id>.service` and `.timer`, running
  `gdash --tenant <id> schedule`, with the same hardening as the
  single-tenant units.

## What was built

- **`gdash_tenants`:** id and host rules, registry validation, `resolve_host`,
  `roles_for`, and create, suspend, resume, delete and list.
- **The registry:** written to a temporary file and renamed into place, at
  mode 0600. `create` writes the role directories and a format stamp
  (`etc/tenant.json`) first and the registry entry LAST, so a half-created
  tenant is unreachable rather than half-open.
- **`gdash_app.tenant_of(req)`** is the one resolution point. All seven
  entry points that took `paths_for(req)` refuse when it fails.
- **CLI:** `tenant create|list|suspend|resume|delete`, `--tenant <id>` on
  every verb, and `--host`/`--base` for `create`.
- **Scheduler:** `--tenant`, and the template units with their install and
  uninstall entries.

## Verified

- **`tests/run_tenants.sh`** (45 assertions, in the full suite), on two
  tenants and one server:
  - the same dashboard name serves each tenant's own data;
  - a dashboard only one tenant has is a 404 at the other;
  - host matching ignores case and port, and a second host names the same
    tenant;
  - an unknown host is refused, including `127.0.0.1`;
  - no traversal spelling reaches the other tenant;
  - a session from one tenant is anonymous at the other, and the cookie names
    no `Domain`;
  - a query naming the other tenant's table finds nothing, and `validate`
    refuses it;
  - suspension refuses only that tenant, and an operator can still act on it;
  - an invalid registry refuses every host;
  - delete makes a tenant unreachable and keeps its directory;
  - seven invalid ids and a host already taken are refused.
- **`tests/test_tenants.bas`** (33 assertions):
  - the id and host rules;
  - registry validation;
  - containment, including a tenant directory symlinked out of the base;
  - resolution with and without a registry, with no `Host`, and with a
    registry that does not read.

## Findings

- **G15-1 — `real_path` of a missing path answers a non-string, without
  raising.** The first version of `root_of` assumed it raised, and
  `starts_with` then raised on the answer. It is handled now. Worth a line in
  gBASIC's reference, which describes the canonical path and not this case.
- **G15-2 — `range` in `gdash_controls` shadowed a built-in.** It was renamed
  `range_dates`. The note appeared only once a CLI path loaded the module.

## Deliberately not built (the design's §6 and §7, and GDASH-16 and 17)

- **A tenant-level gate on `access: open`.** In SaaS, `access: open` publishes
  to the internet. The design wants a tenant policy that defaults to
  forbidden. **This should come before real tenants are onboarded.** It is
  the first item proposed for GDASH-16.
- **Limits:** disk quota, concurrent refresh children, model spend, dataset
  size (GDASH-16).
- **`gdash tenant migrate`.** The format stamp it will read is in place.
- **An operator-side event stream** and onboarding (GDASH-17 and 18).
