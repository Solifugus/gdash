# Making gdash multi-tenant — an assessment

Not a brief. No scope is committed here; this is what the work is, what is
already done, and where the real difficulty sits. Written 2026-09-15 against
the tree at GDASH-13.

**The requirement, restated:** a SaaS deployment serving many tenants from one
installation, with tenant data walled off, and **single-tenant remaining a
first-class deployment option** rather than a special case of the other.

---

## 1. The finding that shapes everything else

gdash is already most of the way there, and not by accident. Three properties
that would each be a rewrite in a typical application are already true, and
they were true before anyone said "tenant":

**Every path comes from one function.** `gdash_paths.roles(root)` returns the
five directories gdash uses, and CLAUDE.md forbids a path literal anywhere else.
`--root <dir>` already collapses all five under one directory — that is how the
test suite runs hermetically. A tenant is therefore *a root*, and the mechanism
for it exists and is exercised on every test run.

**The per-request seam is already cut.** In `gdash_app`:

```basic
function _root_of(req)
    return default(env("GDASH_ROOT"), "")
end function
```

It takes `req` and ignores it. That signature is the entire integration point:
one function decides which tenant a request belongs to, and everything
downstream already takes `p` as an argument.

**There is no cross-request memory to leak.** `grep` finds no program global in
`src/`. Theme, auth config, connection profiles, users, sessions and the CSRF
secret are all read per request from `p`. Workers share no in-memory state
(design §5) — which was done so that per-viewer interactivity could ride
request/response, and pays off here: a worker *cannot* serve tenant A's state
into tenant B's response, because between requests it holds none.

Two more, verified rather than assumed:

- **Sessions are files under `run_dir`.** A session id minted for tenant A and
  presented to tenant B is looked up in B's own `run_dir`, is not found, and the
  viewer is anonymous. Isolation by construction, not by a check someone can
  forget to write.
- **The session cookie sets no `Domain`** (`Path=/; HttpOnly; SameSite=Lax`),
  so it is host-only: `a.example.com` does not send its cookie to
  `b.example.com`. The default is already the safe one; the work is to keep it.

And `req.headers.host` carries the Host header (measured: `acme.gdash.app`), so
subdomain routing needs nothing from the platform.

---

## 2. Tenant as a root, not as a prefix

Your sketch was a tenant id, an optional subdomain, and *"maybe a prefix to
their sqlite database"*. The first two are right. I would not do the third, and
the reason is not stylistic.

**A prefix makes the wall a property of string construction.** Every place that
builds a filename has to get it right, forever, including code not yet written.
One missing prefix is a cross-tenant read, and it is the kind of bug that is
invisible until it is a disclosure.

**A root makes the wall a property of the filesystem.** `/srv/gdash/acme/` and
`/srv/gdash/globex/` cannot see each other because they are different
directories, and gdash's own rule that no path is minted outside the resolver
means there is exactly one function to review.

It is also strictly more, for less:

| | prefix on the dataset files | a root per tenant |
|---|---|---|
| datasets | walled | walled |
| connection credentials | **shared file** | walled |
| model API keys | **shared file** | walled |
| user accounts, password hashes | **shared file** | walled |
| sessions | **shared directory** | walled |
| CSRF secret | **shared** — a token minted for one tenant verifies for another | walled |
| audit log | **shared** | walled |
| delete a tenant | find every prefixed file | `rm -rf` one directory |
| back up one tenant | as above | `tar` one directory |
| OS-level enforcement later | impossible | per-tenant uid, quota, ACL, mount namespace |

The shared-CSRF-secret row is the one I would point at hardest. `secret_of(p)`
reads `config_dir/secret`; if two tenants share a config directory they share
that secret, and a CSRF token is then valid across the boundary.

**What I would not do at all:** tenancy as a column in shared tables. gdash's
model is one SQLite file per dataset, ATTACHed for cross-dataset joins. Making
tenancy a predicate would put the wall *inside every query* — which is precisely
where it can be forgotten, and there are now queries gdash did not write (NLQ).
Keeping the wall outside the query is worth a great deal.

---

## 3. What actually has to be built

### A. Tenant resolution — small, and the part that must be perfect

A registry, server-level, beside the other configuration:

```json
{ "format": 1,
  "tenants": {
    "acme":   { "root": "/srv/gdash/acme",   "hosts": ["acme.example.com"], "status": "active" },
    "globex": { "root": "/srv/gdash/globex", "hosts": ["globex.example.com", "bi.globex.com"], "status": "suspended" } } }
```

`_root_of(req)` maps Host → tenant → root. Three rules, and they are the whole
security argument:

1. **An unknown host is refused.** Not a default tenant, not the first tenant,
   not the single-tenant root. The failure this prevents is the one that
   matters: *resolution failed, so serve something*.
2. **Resolution happens once, at the edge, and yields `p`.** Nothing downstream
   re-derives a tenant from anything. This is already true by accident — every
   function takes `p` — and should become true by design.
3. **A suspended tenant is refused at resolution**, not hidden in the UI.

**Tenant ids need stricter validation than dashboard names.** Today a dashboard
name is checked only for `/`:

```
name ".."  ->  /srv/gdash/acme/lib/dashboards/../draft.json
```

That escapes into `lib/` — contained within the tenant, and it resolves to a
file that does not exist, so there is no disclosure today. It is nevertheless
exactly the pattern that must not be repeated one level up, where the segment
being interpolated is the tenant. A tenant id should be
`^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$` — no dots, no slashes, no case — and the
resolved root should be checked with `real_path` against the tenant base on a
separator boundary, which is what the platform reference recommends for exactly
this.

Single-tenant costs nothing: **no registry file means today's gdash**, with
`GDASH_ROOT` or the FHS paths. That is the deployment option you asked to keep,
and it falls out rather than being maintained separately.

### B. The CLI and the scheduler — medium, with one real unknown

The CLI takes `--root`; it will want `--tenant` resolving through the registry,
and an "all tenants" form for operator tasks.

The scheduler is the real unknown. Today it is **one process, one root**, and
refreshes are **synchronous** — `gdash_refresh.run` calls `process.wait` on the
child. One tenant's slow or hanging source therefore stalls every tenant behind
it on that scheduler. Three shapes, and I would want the measurement before
choosing:

- a scheduler process per tenant — simple, isolates badly-behaved sources, does
  not scale past some number of tenants nobody has measured;
- one scheduler with a bounded pool of concurrent children and per-tenant
  fairness — better, and needs the refresh path to stop blocking;
- a queue with workers — most capable, most new machinery.

This is the first place where SaaS asks for something the current design does
not already lean toward, and it should open with a measurement rather than a
decision.

### C. Fail-closed review of what is currently "per deployment" — medium, security-critical

Several things are safe because a deployment is one organisation. That premise
goes away:

- **`access: open` means the public internet.** It is a per-dashboard opt-in
  that returns `true` for an unauthenticated viewer. On an intranet that is a
  reasonable choice; in SaaS it is publishing. It needs a tenant-level policy
  gate, defaulting to forbidden, so a tenant cannot publish by editing one line
  of a record.
- **Credentials.** Connection profiles hold tenant database passwords; models
  hold API keys. Per-tenant 0600 files are already the shape. What is new is
  that the *operator* can read all of them, which is a statement to make
  explicitly in the operations document rather than leave implied.
- **Throttling** is per-root, so per-tenant, which is right: a brute-force
  attempt against one tenant must not slow another's logins.
- **The audit log** is per-tenant and should stay so. SaaS additionally needs an
  operator-side event stream — sign-ins, refresh failures, spend — which does
  not exist.

### D. Resource isolation — the genuinely hard part, and mostly new

Nothing here exists today, and none of it is hard to *reason* about; it is
simply absent.

- **Disk.** A refresh writes whatever the source returns. One tenant can fill
  the volume for everyone. Needs a per-tenant cache quota and a refusal that
  leaves the old dataset intact — which fits gdash's stale-but-coherent rule
  exactly, so the failure mode is already designed.
- **Processes.** A refresh spawns an interpreter per dataset. Needs a ceiling
  per tenant and overall.
- **Model spend.** NLQ costs real money per question, and a tenant can spend
  it. A per-tenant budget with a refusal when exhausted is new machinery, and it
  is the item most likely to be discovered by a bill rather than by a test. If
  SaaS is the goal, I would build this before opening the ask feature to
  tenants, not after.
- **Polling.** Each open dashboard polls `/d/{name}/version` every 5 s at a
  measured ~28 ms per request. One deployment does not notice; a thousand
  concurrent viewers is ~200 req/s of pure polling before any page is rendered.
  Not a blocker, but an input to sizing and possibly to a cheaper endpoint.

### E. Tenant lifecycle — new, and small if the root decision is taken

Create, suspend, resume, delete, export. Deletion is `rm -rf` of one directory
and export is `tar` of one directory — which is the practical argument for the
root-per-tenant shape, and it is also what a deletion request obliges you to be
able to do quickly and provably.

### F. Operations — medium

- One server process serving all tenants; one systemd unit, not one per tenant.
- TLS is already the proxy's job (gdash refuses to serve it — see
  `gdash8_platform_report_tls.md`), and in SaaS the proxy is a given. It becomes
  the tenant router as well, and wants a wildcard certificate.
- Backups become per-tenant directories, which the existing backup section
  almost describes already.
- **G8-7 is still open and gets more urgent, not less:** the systemd units have
  been `systemd-analyze verify`'d and never actually started.

---

## 4. What I would insist on

1. **Unknown host refuses.** No default tenant, ever, in any code path.
2. **One resolution point.** Tenant is decided once, yields `p`, and nothing
   downstream re-derives it.
3. **A two-tenant suite that asserts the wall**, in the shape of
   `run_workers.sh`: two roots, one server, and assertions that a session from A
   is anonymous at B, that a dashboard name known to A is a 404 at B, that
   `..` and its relatives are refused as tenant ids and as dashboard names, that
   an ATTACH never crosses roots, and that an unknown Host is refused. Isolation
   that is not executed on every run is isolation nobody can vouch for a year
   from now.

---

## 5. Rough shape of the work

Deliberately coarse; the scheduler item is the one with a genuine unknown in it.

| | what | size | risk |
|---|---|---|---|
| 1 | Registry, resolution, validation, fail-closed, two-tenant isolation suite | **small** | low — the resolver already exists |
| 2 | CLI `--tenant`; scheduler fairness and non-blocking refresh | **medium** | **the one real unknown** |
| 3 | Quotas, process ceilings, model budgets, lifecycle | **large** | mostly new code, low conceptual risk |
| 4 | Operator plane: cross-tenant view, spend and abuse signals, billing hooks | **large** | arguably a separate product |

Phase 1 is small **because of decisions already made** — the resolver, the
absence of shared state, and sessions being files. It is worth saying plainly
that this is the dividend from those rules, since they each cost something at
the time.

---

## 6. What has not been measured

Stated rather than assumed, and each is a step-0 for the phase that needs it:

- The scheduler under several roots. Everything about §3B is reasoning, not
  measurement.
- The server under many tenants' worth of concurrent viewers. The ceiling work
  in GDASH-11 measured 30 viewers on one worker; nothing has measured 3,000
  across 100 tenants.
- Whether one `gdash_web` process with a registry lookup per request costs
  anything worth noticing. It should not — it is a small file read that already
  happens for auth config — but "should not" is not a number.

---

## 7. Owed to the maintainer

The design document describes a single deployment throughout. Multi-tenancy is
not a contradiction of any ruling in it, but it is not contemplated by it
either, and §6 (deployment) and §8 (access) would both need a paragraph. That
is a design change, and this document is the finding rather than the edit.
