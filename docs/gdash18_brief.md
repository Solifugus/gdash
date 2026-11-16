# GDASH-18 — The onboarding surface

**Status:** step 0 run (2026-11-16). **Stopped**: what gcorp expects of a
product installation decides this phase's shape, and the two designs
disagree.
**Authority:** `gdash_design.md` outranks this brief. The plan's entry: "an
admin endpoint in front of the same code the CLI calls, for a remote
onboarding service to drive … the CLI is the API".

## Step 0

- **gcorp provisions locally, not remotely.** In `~/development/gcorp`
  (commit 3b75db3, 2026-11-14, known to be stale), the business service
  drives a **tenant-host service on the same VM as the installations**,
  over a "Provisioning MCP" (`gcorp-design.md` §3.2, §11.2). That service
  can call gdash's CLI directly. A remote HTTP admin endpoint on gdash, as
  the plan imagined, would be a second way in that gcorp does not need.
- **gcorp's design proposes a container per installation.** §3.2:
  "folders and databases alone do not isolate execution. Proposed: a
  container per installation." gdash's multi-tenancy
  (`gdash_saas_design.md`) is the other model: one server process holds
  many tenants, each a directory, isolated by the filesystem and by sharing
  no state between requests. **This is the decision.** Each model shapes
  this phase differently:
  - **A container per installation:** each customer's gdash is a single
    root. Provisioning is installing gdash in the container and adding a
    first admin. Limits are the container's plus gdash's single-root
    limits, and backup is the single root's. GDASH-15 to 17's tenant layer
    would go unused by gcorp.
  - **gdash's own tenants, one server per host:** provisioning is `tenant
    create`, `tenant limit` and a first admin. Suspension, export, purge
    and usage are the GDASH-16 and 17 verbs. This phase makes them
    something a program can drive safely.
- **G18-1: concurrent registry changes lose updates.** Eight `tenant
  create` calls run at once registered five tenants. All eight directories
  were made, so three were orphaned, and their callers were very likely
  told they had succeeded. Every registry change reads, edits and writes
  the file without a lock. A provisioning service that retries, or runs
  jobs in parallel, would hit this. This is a GDASH-15 defect, and it needs
  fixing under either model wherever the registry is used.
- **A tenant created by a program gets no scheduler.** Its refreshes run
  only once `systemctl enable --now gdash-scheduler@<id>.timer` is run as
  root. gcorp's host service would have to do that itself, or gdash would
  need one root-run dispatcher that starts each tenant's pass as its own
  process.

## What gcorp's design asks of any product

From §11.2 and §8: every provisioning step **restartable and idempotent**,
with stable idempotency references; **validated parameters only**, never a
shell command from a frontend; **health checks**; **storage usage** for
capacity (§11.4); a lifecycle of active, grace, suspended and retained,
deletion eligible, and deleted, with **export during suspension** defined
per product; and a payment racing a deletion must not destroy a renewed
tenant.

## Proposed, under gdash's own tenants

- **G18-1 fixed:** every registry change takes a lock.
- **A machine-readable CLI**, the surface gcorp's host service calls:
  `--json` on every tenant verb, one JSON object on stdout, and exit codes
  that separate "refused" from "failed".
- **Idempotent verbs.** Repeating `tenant create` with the same id and hosts
  answers "already so". Suspend, resume and limit settings are naturally so.
- `tenant health <id>` (registry, stamp, limits, writability, owners) and
  `tenant usage <id>` (disk, spend, dataset counts).
- A first admin through the same verb, with the password on stdin, never in
  argv.
- Purge refused while a newer export, or a resume, is pending: §8's
  payment-versus-deletion race.
- The scheduler question decided: a dispatcher, or documented as the host
  service's job.

No HTTP endpoint unless gcorp needs one from off the host.
