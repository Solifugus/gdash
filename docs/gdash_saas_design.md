# gdash — Multi-tenancy design

**Status:** proposed. `gdash_design.md` outranks this document; where the two
disagree, that is a finding to report, not a silent edit to either.

This is the architecture for serving many tenants from one installation. It is a
**dimension added to** the existing design, not a replacement: single-tenant
remains a first-class deployment and is what you get by doing nothing.

Section numbers below in the form *design §5* refer to `gdash_design.md`.

---

## 1. What a tenant is

**A tenant is a root.** One directory containing the five roles the resolver
already mints (design §6), with nothing shared with any other tenant:

```
/srv/gdash/acme/
  etc/    connections.json  users.json  auth.json  models.json  secret  theme.json
  lib/    dashboards/  snapshots/
  cache/  staged dataset files
  log/    audit.log
  run/    sessions, login-throttle counters
```

This is not a new layout. It is exactly what `--root` produces, which is what
every test run has used since GDASH-0.

**The wall between tenants is the filesystem, not the code.** Two tenants cannot
see each other because they are different directories, and gdash's standing rule
that no path is minted outside `gdash_paths` means there is exactly one function
to review in order to believe that.

### Why not a prefix, a shared directory, or a tenant column

A prefixed filename makes the wall a property of **string construction** — every
site that builds a name must get it right forever, including code not yet
written, and one miss is a cross-tenant disclosure that is invisible until it is
a breach. It also walls off only the datasets, leaving the CSRF secret, source
credentials, model keys, password hashes, sessions and the audit log in a shared
directory. A shared `secret` is the sharpest of those: `secret_of(p)` reads
`config_dir/secret`, so two tenants sharing a config directory share the secret
that signs CSRF tokens, and a token minted for one verifies for the other.

A tenant **column** in shared tables would be worse still: it puts the wall
*inside every query*, which is where it can be forgotten — and gdash now runs
queries it did not write (GDASH-12). Keeping the wall outside the query is worth
a great deal.

---

## 2. Resolution

**One function decides which tenant a request belongs to, and it runs once.**

`gdash_app._root_of(req)` already takes the request and ignores it; that
signature is the whole integration point. It becomes: read the Host header, look
it up in the registry, return that tenant's root. Everything downstream already
takes `p` and needs no change.

### The registry

Server-level, beside the other configuration, and the single source of truth:

```json
{ "format": 1,
  "tenants": {
    "acme":   { "root": "/srv/gdash/acme",   "hosts": ["acme.example.com"],
                "status": "active",    "format": 1 },
    "globex": { "root": "/srv/gdash/globex", "hosts": ["globex.example.com", "bi.globex.com"],
                "status": "suspended", "format": 1 } } }
```

### Three rules, and they are the whole security argument

1. **An unknown host is refused.** Not a default tenant, not the first tenant,
   not the single-tenant root. The failure being designed against is *resolution
   failed, so serve something* — which is how multi-tenant systems leak.
2. **Resolution happens once, at the edge, and yields `p`.** Nothing downstream
   re-derives a tenant from a cookie, a path, a form field or a record. This is
   already true because every function takes `p`; it becomes true **by design**
   rather than by luck.
3. **A suspended tenant is refused at resolution**, not hidden in the UI.

### Identifier validation

A tenant id is `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$` — no dots, no slashes, no
case — and the resolved root is checked with `real_path` against the tenant base
on a separator boundary.

This is stricter than the dashboard-name rule on purpose. A dashboard name is
checked only for `/`, so `..` resolves to `lib/draft.json`: contained inside the
tenant, a 404 today, no disclosure — and precisely the pattern that must not be
repeated one level up, where the interpolated segment *is* the tenant.

### Single-tenant is the absence of a registry

**No registry file means today's gdash**, resolving `GDASH_ROOT` or the FHS
paths exactly as it does now. The single-tenant deployment is not a tenant count
of one; it is a different and simpler code path that continues to exist.

---

## 3. What isolation rests on

Four properties, each verified in the tree rather than asserted:

**No cross-request state.** There is no program global in `src/`. Theme, auth
config, connection profiles, users, sessions and the CSRF secret are all read
per request from `p`. Workers share no in-memory state (design §5) — a rule
adopted so per-viewer interactivity could ride request/response, and it means a
worker *cannot* serve one tenant's state into another's response because between
requests it holds none.

**Sessions are files.** A session id minted for tenant A and presented to tenant
B is looked up in B's own `run_dir`, is not found, and the viewer is anonymous.
Isolation by construction, not by a check someone can forget.

**The session cookie sets no `Domain`** (`Path=/; HttpOnly; SameSite=Lax`), so
it is host-only and subdomain tenants do not share it. The default is already
the safe one; the work is to keep it.

**Every query is read-only and inside one root.** Since GDASH-20, each
dashboard's data is its own G-SQL database under its tenant's cache
directory, and every read runs in a read transaction. A generated query
cannot write, and cannot name a table outside its own dashboard, let alone
its tenant. *(Corrected 2026-11-08; this said "every ATTACH is read-only",
which described the SQLite store.)*

---

## 4. Deployment shape

**Failover is not a day-one requirement** (ruled 2026-09-15). Reboots and
downtime are acceptable though not desirable. That ruling is load-bearing for
everything below.

### One tenant, one server, local disk

```
proxy (TLS, routes by subdomain)
   acme.example.com    -> server 1   /srv/gdash/acme
   globex.example.com  -> server 1   /srv/gdash/globex
   initech.example.com -> server 2   /srv/gdash/initech
```

Horizontal scale is **partitioning**, not sharing: each server owns a set of
tenants outright. Moving a tenant is stop, copy, repoint, start. No shared
filesystem, no distributed locks, no consistency window, no split-brain.

Because a tenant lives on exactly one server, **one writer per tenant** is a
fact of the layout rather than a rule to enforce. It is nevertheless written
down as an invariant, because if uptime later requires shared storage, that
stays a placement change instead of becoming a locking project.

### One server process, one scheduler process per tenant

The server is a single process tree serving every tenant on the box; it holds
nothing between requests, so its cost does not grow with tenant count. The
scheduler is per-tenant, as a systemd template unit (`gdash-scheduler@acme`).

Measured 2026-09-15: an idle scheduler is **4.1 MB RSS**, and a four-worker
server is **~75 MB** in total. A few hundred tenants per box on ordinary
hardware, with **better** isolation than a shared scheduler pool would give —
separate processes cannot stall each other at all, where a pool needs fairness
logic to approximate that.

**The trade-off this accepts.** A single scheduler serialized refreshes for free
by blocking on `process.wait`. Per-tenant schedulers do not: up to N refresh
children may run at once, and a refresh child holds its entire result set in
memory. The cost model therefore moves from scheduler count to **concurrent
refresh count**, and that is what must be bounded.

### TLS

Terminated at the proxy. In SaaS the proxy is a given and becomes the tenant
router as well, wanting a wildcard certificate. *(Corrected 2026-11-08: gdash
can now serve TLS directly too, which a single-tenant box may prefer; it
refused to until gbasic `d643f9b1`.)*

---

## 5. Provisioning

A tenant directory is nearly empty, because gdash already treats almost every
configuration file as optional with a defined default: absent `connections.json`
means no profiles, absent `models.json` means no model, absent `auth.json` means
local accounts, absent `theme.json` means the built-in theme, absent `secret`
means one is minted.

So creating a tenant is: make five directories, create a first admin, write one
registry entry.

**Written in that order, with the registry entry last.** The registry is what
makes a tenant resolvable, so a partially created tenant is unreachable rather
than half-open. This is the shape publish already uses: write the snapshot, then
rename the pointer.

**Built by code, not copied from a skeleton.** A template directory is data, and
data drifts — a file that becomes required later will not be in a template
written earlier. An optional overlay on top of what code creates ("every tenant
starts with our sample dashboard and our theme") is a separate and useful thing.

**The CLI is the API.** An onboarding service calls `gdash tenant create`; it
does not write gdash's files. This is the argument gdash already makes about
`gdash_store` being the only staging-store access — a second writer is a second
source of truth about a format that will change. A remote onboarding service
wants a small admin endpoint in front of the same code, never filesystem access.

**Each tenant carries a format stamp**, so that `gdash tenant migrate` knows
what it is looking at. With one root this never arose; with hundreds, every
upgrade must migrate all of them.

---

## 6. What changes because a deployment is no longer one organisation

**`access: open` means the public internet.** It is a per-dashboard opt-in that
returns true for an unauthenticated viewer. On an intranet that is a reasonable
choice; in SaaS it is publishing. It needs a tenant-level policy gate defaulting
to forbidden, so that a tenant cannot publish to the world by editing one line
of a record.

**Credentials are readable by the operator.** Connection profiles hold tenant
database passwords and `models.json` holds API keys, at 0600 in the tenant's own
`etc/`. That the operator can read them is a fact to state explicitly in the
operations document rather than leave implied.

**Throttling stays per-tenant**, which is correct: a brute-force attempt against
one tenant must not slow another's logins.

**The audit log stays per-tenant**, and SaaS additionally needs an operator-side
event stream — sign-ins, refresh failures, spend — which does not exist.

**Downtime is acceptable; data loss is not.** Those are separate promises. Each
tenant is one directory, so backup is `tar` of it and deletion is `rm -rf` of
it, both of which want to be exercised before they are needed.

**A reboot signs everyone out**, because `run/` is tmpfs under FHS and the
operations document calls that correct. Acceptable under the ruling above, and
better as a sentence a tenant has read than as something they discover.

---

## 7. Limits, and who they belong to

None of this exists today.

| limit | why it must exist | shape |
|---|---|---|
| tenant disk quota | a refresh writes whatever the source returns; one tenant can fill the volume | refuse the refresh, leave the old dataset intact — which is the stale-but-coherent rule already |
| concurrent refresh children | per-tenant schedulers removed the accidental serialization | a global cap, plus a per-tenant cap |
| model spend | NLQ costs real money per question and a tenant spends it | a per-tenant budget with a refusal when exhausted |
| dataset size | a refresh holds the whole result set in memory | a documented number, measured, and a refusal above it |

The model budget is the one most likely to be discovered by a bill rather than
by a test, and it should exist **before** the ask feature is opened to tenants.

---

## 8. Keeping uptime work cheap to add later

Deferring HA costs nothing later provided four things stay true. All four are
true today and require attention rather than effort.

1. **No cross-request state in the process.** An in-memory cache with a lifetime
   longer than a request is the single change that would make both HA and
   partitioning materially harder.
2. **The filesystem remains the only coordination mechanism.** Atomic rename
   plus polled files is what lets participants that share nothing work at all.
3. **`run/` remains genuinely disposable.** If sessions must survive a reboot,
   that should stay a path change rather than a redesign.
4. **One writer per tenant remains an invariant**, even while the layout makes
   it automatic.

---

## 9. What the main design document would need

Stated here rather than edited there. Each is a sentence or a paragraph, and
each is the maintainer's to make:

- **§6 (Storage layout)** describes one deployment's five roles. It would need
  to say that a deployment may hold many roots, and that a tenant is one.
- **§8 (Identity)** is written as though a deployment is one organisation. It
  would need the tenant boundary, and a ruling on `access: open` in a
  multi-tenant deployment.
- **§5 (Server architecture)** says workers share no in-memory state. That
  sentence is what makes multi-tenancy safe, and it is worth saying so where it
  is stated, because a future optimisation would otherwise look harmless.
- **§3 (Execution model)** would need the refresh-concurrency limit, once it
  has a shape.

---

## 10. Deliberately not in this design

- **Row-level or schema-level tenancy.** §1 says why.
- **Cross-tenant anything** — shared dashboards, shared datasets, a marketplace.
  Each would put a hole in the wall, and none has been asked for.
- **Per-tenant custom code, plugins or SQL functions.** A tenant supplies
  records and queries, not code.
- **Automatic failover and shared storage.** Ruled out for day one; §8 keeps the
  door open.
- **A billing system.** Spend *measurement* is in §7 because it is a safety
  limit; invoicing is a different product.
