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

## 3A. Provisioning a tenant — smaller than it looks

A new tenant directory is **nearly empty**, because gdash already treats almost
every configuration file as optional with a sensible default:

| file | absent means |
|---|---|
| `etc/connections.json` | no source profiles — every dataset fails by name, which is the right message |
| `etc/models.json` | no model — `gdash ask` says so and names the file |
| `etc/auth.json` | local accounts only, which is the documented default |
| `etc/theme.json` | the built-in theme |
| `etc/secret` | **minted on first use**, under a lock |
| `lib/dashboards/` | an empty index page, correctly |

So provisioning is: make five directories, create a first admin, write one
registry entry. Everything else is the tenant's to add later. That is a small
command, not a subsystem.

**The order matters, and it is the order gdash already uses elsewhere.** Create
the directories, create the admin, and write the **registry entry last** —
because the registry is what makes a tenant resolvable, a half-created tenant is
simply unreachable rather than half-open. That is the same shape as publish:
write the snapshot, then rename the pointer.

**Code, not a copied skeleton.** A template directory is data, and data drifts:
a file that becomes required in a later version will not be in a template
written against an earlier one. A `gdash tenant create` that *builds* what a
tenant needs is versioned and testable in the way the rest of gdash is. An
optional overlay on top — "every tenant starts with our sample dashboard and our
theme" — is worth having and is a different thing from the skeleton itself.

**The CLI is the API.** An onboarding site — yours, serving several products —
should call `gdash tenant create` rather than write gdash's files itself. This is
the argument gdash already makes about `gdash_store` being the only staging-store
access: a second writer is a second source of truth about a format that will
change. A remote onboarding service wants a small admin endpoint in front of the
same code, never direct filesystem access.

**Stamp a format version at creation.** With one root this never came up; with
hundreds, an upgrade has to migrate every one of them. `{"format": 1, "created":
...}` per tenant costs nothing now and is expensive to retrofit, and it is what
lets `gdash tenant migrate --all` know what it is looking at.

## 3B. Scale, in the two directions it goes

### One tenant's data — there is a real ceiling, and it is a wall not a slope

A refresh fetches the whole result set into memory (`got.rows`), plans the
columns from it, materializes it into a staging file, and renames that over the
live one. Three consequences, none of them subtle:

- **A dataset is bounded by the refresh child's RAM.** Not by disk.
- **There is no incremental refresh.** Every refresh rewrites the whole dataset.
- **Eleven datasets per dashboard**, because a visual query attaches every
  sibling and SQLite attaches ten databases beside the one being queried. Already
  refused at load rather than at render.

This suits what gdash is for — aggregates and summaries, not raw event logs —
and it should be said out loud to a tenant before they point a dataset at a
fifty-million-row table. It is also the most likely first thing a real customer
hits, which makes it worth a measurement and a documented number rather than a
shrug.

### Many tenants — the easy direction

Requests are stateless and hold nothing between them, so more tenants means more
requests, not more state. The server scales the way any stateless web
application does. The registry lookup is one small file read per request, in a
request that already reads several.

The scheduler is the exception, and it is the same problem named in §3B above:
it walks one root and blocks on each refresh.

## 3C. More than one server

### Partition first. It is much simpler and it is available immediately.

Because a tenant is a self-contained directory that shares nothing, horizontal
scale does not need a distributed anything:

```
proxy (routes by subdomain)
   acme.example.com   -> server 1   /srv/gdash/acme
   globex.example.com -> server 1   /srv/gdash/globex
   initech.example.com-> server 2   /srv/gdash/initech
```

Each server runs one gdash and one scheduler, and owns a set of tenants
outright. Moving a tenant is: stop its scheduler, rsync the directory, repoint
the proxy, start. No shared filesystem, no distributed locks, no consistency
questions, no split-brain.

This is a stronger position than most applications get to start from, and it is
a direct consequence of the tenant-is-a-directory decision. **I would do this
first and treat shared storage as a later requirement rather than an
architecture.**

### Shared disk — when you need it, and the three things to watch

Shared storage buys one thing partitioning does not: **any server can serve any
tenant**, which is what failover and not-managing-placement need.

gdash is unusually well suited to it. Its coordination is a single atomic
`rename` plus files that other processes poll — the design already assumes
participants that share nothing but a filesystem. And the whole codebase takes a
file lock in exactly **two** places: minting the CSRF secret, and a dataset
refresh.

Three things to watch, in the order I would test them:

1. **File locking over a network filesystem is the classic hazard**, and gdash
   has only two sites to reason about. Mint the secret at provisioning time and
   one of them disappears. The other degrades well: if two servers both refresh
   a dataset, the loser's work is discarded by an atomic rename, so the failure
   is *duplicated effort*, not corruption. That is a good position to be in, and
   it should be measured rather than assumed.

2. **SQLite on a network filesystem** is conventionally discouraged, and the
   reason is concurrent writers contending on POSIX locks over one file. gdash
   does not do that: writers write a *staging* file and rename, and as of
   GDASH-13 every reader attaches `mode=ro`. Worth testing `immutable=1` for
   dataset reads, which skips SQLite's locking entirely and is arguably *true*
   under a rename-swap model — an opened file keeps its inode when a rename
   replaces the directory entry.

3. **`run/` is the directory that actually forces the decision.** Sessions live
   there, so either it is shared or the proxy pins a viewer to one server. The
   login throttle lives there too, and per-server throttling means three free
   attempts *per server* — a dilution worth naming rather than discovering.

### The rule that makes shared disk easy: one writer per tenant

Even on shared storage, let exactly one server be the **writer** for a given
tenant — its refreshes and publishes — while any server may read. The scheduler
is already a separate process, so this is a placement decision rather than new
code, and it removes almost all of the locking question rather than answering it.

The operations document already sorts gdash's five directories by whether they
need backing up, and that classification maps almost exactly onto what needs to
be shared:

| | | shared? |
|---|---|---|
| `etc/` | configuration, credentials | yes — small, rarely written |
| `lib/` | dashboards, snapshots | yes — this is the durable data |
| `cache/` | staged datasets | **could be local**: it is disposable and refetches, at the cost of each server refreshing independently |
| `log/` | audit | shared, or shipped off the box |
| `run/` | sessions, throttle | yes, or pin viewers to a server |

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
