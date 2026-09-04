# GDASH-5 — Directory auth and personalization: phase brief

**Status:** OPEN. Step-0 complete and written up in `gdash5_findings.md`
(G5-1 … G5-8); it failed once, was escalated, and now passes against a real
directory.
**Narrows:** the GDASH-5 paragraph of `gdash_development_plan.md`.
**Authority:** `gdash_design.md` outranks this brief. The findings of GDASH-0
through GDASH-4 are inputs, not open questions.

GDASH-4 gave gdash people, provisioned one at a time by whoever runs the
server. That is the right bootstrap tier and the wrong steady state for an
organization that already knows who its people are. This phase lets gdash ask
the directory.

---

## 1. Step-0 verification

Full write-up in `gdash5_findings.md`. The short form, in the order it
happened:

- **It failed.** There was no LDAP client, no raw socket to write one over,
  and no `ldapsearch` to shell out to (G5-1). Hand-rolling BER over TLS for an
  authentication path would have been the wrong answer even with a socket: the
  only thing worse than no directory support is directory support that appears
  to work. The phase stopped and the platform was asked, with `smtp` named as
  the precedent — native transport, gBASIC policy above it (G5-2).
- **The module landed** at gbasic `d2dc8fb` with exactly that shape, and the
  platform said it had never met a real directory and asked gdash to point it
  at one. It has now: rootless `podman` runs a real **OpenLDAP 2.6.10** on
  loopback, seeded by `scripts/ldap_test_directory.sh` (G5-3, G5-7).
- **Three things came back from that, and all three are fixed** at gbasic
  `bcd0258` (G5-8): `empty_password` is a distinct reason; a TLS failure
  arrives as `bind` returning `tls_failed` instead of raising from `connect`;
  and `ldap_design.md` now states the `memberOf` assumption rather than
  carrying it silently.
- **The fourth finding is gdash's, and it is the one that shapes this phase.**
  Design §8 says LDAP "yields `memberOf` groups". Stock OpenLDAP does not
  populate `memberOf` — the overlay is off by default — so a provider that
  reads only that attribute gets **zero groups**, which is a legitimate answer
  and therefore fails silently (G5-4). Every group-gated dashboard would refuse
  everyone while the log showed successful logins.
- **Never ask for every attribute.** A search with no `attributes` list
  returns everything the bind identity may read; bound as the directory admin
  that included `userPassword` (G5-6).

Verified additionally for this phase's shape: `load ldap` succeeds on this
build; a bind, a search, and a `member=` group lookup all work against the
container; and `connect` still raises for `security: "none"` and for an
omitted `security`, which is correct and is a configuration error rather than
a runtime condition.

## 2. Scope — the narrowing

### 2.1 The provider interface

`gdash_auth` owns the rules and **touches no directory and no file**. It takes
a provider — **a record of function values**, the same seam shape the platform
required for the session store in GDASH-4 and for the same reason:

```
provider = { kind:         "local" | "ldap",
             name:         <string, for the audit log>,
             ctx:          <opaque configuration>,
             authenticate: fn(ctx, username, password) -> outcome,
             identity:     fn(ctx, username)           -> outcome,
             revalidate:   <seconds; 0 means every request> }

outcome  = { ok, known, message, identity }
identity = { name, email, groups, admin }
```

`gdash_users` supplies the local implementation, `gdash_auth_ldap` the
directory one, and the hermetic tests supply a third that is neither — a
scripted provider that answers from a table, so the seam is exercised by
something that is not a near-copy of either shipped implementation. That is
what GDASH-4 did with the session store and it is why the store double caught
what it caught.

**`known` is a separate fact from `ok`,** and it is the whole reason the
outcome is a record rather than a boolean. It means *this provider has this
username* — not *this password was right*. The chain stops at the first
provider that says `known`, whatever `ok` says. Without that, one typo at the
login form becomes one failed bind per configured directory, and in AD a
failed bind is a step toward a lockout. A wrong password must cost the
directory exactly one attempt, the same as it would if the user had typed it
at any other application.

### 2.2 The chain: local first, always

Providers are consulted in one fixed order: **local accounts, then the
directory.** Not configurable, and local is never absent.

Design §8 makes local "the base tier and bootstrap — first admin before any
directory exists". That is also the break-glass tier, and break-glass only
works if it works when the directory does not. If the directory were consulted
first, then a directory that is down, misconfigured, or answering `unreachable`
would take the local administrator down with it — locking the operator out of
the server at precisely the moment they need to fix the directory
configuration.

The cost of that order is real and is stated rather than hidden: **a local
account shadows a directory account of the same name.** That shadow is visible
in `gdash user list`, was created by an operator on purpose, and is removable
with one command. The reverse failure is neither visible nor removable from
outside the box.

**Exactly one directory provider.** Design §8 describes three tiers, not a
federation, and the plan's paragraph is singular. Multiple directories, a
provider-selection control on the login form, and per-provider username
namespacing are not built and are named in §6.

### 2.3 Finding the user: template or search, never both

A directory provider names exactly one way to turn a username into a DN.
Validation refuses a profile that names both or neither.

- **`user_dn_template`** — `"uid={user},ou=people,dc=example,dc=invalid"`.
  No service account, one round trip, and the bind is the only operation. This
  is the simple deployment.
- **`user_search`** — `{ base, scope, filter: "(uid={user})" }`, performed as
  a service account (`bind_dn` + `bind_password`) or anonymously. Required
  when the DN is not derivable from the username, which is most of AD.

`{user}` is the only placeholder and **the username is attacker-controlled
text going into a DN or a filter.** It is escaped per RFC 4514 for a DN and
RFC 4515 for a filter, in `gdash_auth_ldap`, on every path, with no exception
for "it came from our own form". An unescaped `*)(uid=*` in a filter is an
authentication bypass, not a formatting bug. This is a hermetic test, not a
live one.

**Template mode cannot answer `known` without binding**, since a nonexistent
DN and a wrong password are deliberately the same answer (G5-3 — no
enumeration oracle). So in template mode `known` is true whenever the
directory answered at all. That is correct for a two-provider chain and is
part of why the chain is two providers.

### 2.4 Group strategy: named, with no default

The G5-4 ruling, in force and unmodified:

> The group strategy is named in configuration, with no default. A profile
> says either `memberof` (read the attribute) or `search` (find groups whose
> `member` is the user's DN, given a base and a filter). Not auto-detected and
> not fallen back to, for the same reason the platform gave for requiring
> `security`: guessing wrong here produces a plausible answer rather than a
> failure, so it has to be a word somebody typed and can be found in a
> configuration review.

- **`memberof`** — read `group_attribute` (default `memberOf`) from the user
  entry. Each value is a group DN.
- **`search`** — search `group_base` with `group_filter` (default
  `"(member={dn})"`), reading `group_name_attribute` (default `cn`).

Both yield DNs or attribute values that must become the plain group names a
record's `view_groups` names. `group_names` says which: `"rdn"` (default —
`cn=analysts,ou=groups,dc=…` becomes `analysts`) or `"dn"` (the full DN, for
an organization that would rather write DNs in its records than trust an RDN
to be unique). A `search` strategy reading `cn` already has the name; `rdn`
is what a `memberof` strategy needs.

**Every attribute is named explicitly, always** (G5-6), and no attribute
record is logged, audited, or put into a dashboard record. What gdash reads is
exactly: the email attribute, the display-name attribute, and — in `memberof`
mode — the group attribute. Nothing else, ever.

### 2.5 Admin, from a group

A directory has no `admin` column. `admin_groups` in the provider profile
names the groups whose members are gdash administrators; empty (the default)
means **no directory user is an administrator**, which is the fail-closed
answer and leaves the local admin as the only one. An operator who wants
directory admins types a group name.

### 2.6 Revalidation, and what a session remembers

GDASH-4 re-resolves the identity from `users.json` on **every request**, which
is how "the account was disabled while the session lived" takes effect at
once. A directory cannot be asked that on every request.

So the identity is **materialized into the session record at login** and
revalidated when it is older than the provider's `revalidate` seconds
(default 300; `0` means every request, which is what `local` uses, preserving
GDASH-4's behaviour exactly). A revalidation that finds the user gone or
disabled destroys the session, as today. A revalidation that cannot reach the
directory **leaves the session standing until its ordinary expiry** and says
so in the audit log — because a directory outage that logs everyone out
turns a directory problem into a total outage, and the session's absolute and
idle limits still bound it.

This is stale-but-coherent applied to identity, and it is the same ruling as
design §3's for data: bounded staleness beats a hard failure, and the bound is
configuration rather than accident. **Group changes take effect within
`revalidate` seconds** and that sentence goes in the format doc, because an
operator who removes someone from a group deserves to know when it bites.

### 2.7 Preview-as

An editor answers "what does this dashboard look like to somebody in
Shipping?" without borrowing a password. Three restrictions, all from design
§8, and a fourth that follows from them:

1. **Draft only.** Never in published mode. A published dashboard renders for
   the viewer who asked for it and nobody else.
2. **Editors only.** The viewer must already pass `edit_groups` for that
   dashboard, or be an admin.
3. **Audited.** Every preview-as records the real identity, the assumed one,
   and the dashboard. The audit line names who was pretending, not just that
   somebody was.
4. **It changes `user_*` and nothing else.** Preview-as substitutes the
   injected identity params. It does **not** re-run authorization as the
   assumed identity — you cannot preview-as your way into a dashboard, and you
   cannot preview-as your way into being an admin. Authorization stays the
   real viewer's throughout. Anything else would make preview-as a privilege
   escalation with a friendly name.

The assumed identity is typed by the editor: name, email, groups. It is not
looked up in the directory, because "show me this as a plausible member of
Shipping" is the actual question and requiring a real colleague's account to
answer it invites borrowing one.

### 2.8 Auth profiles

Server-level, `<config>/auth.json`, mode 0600, `format: 1` — the same
treatment as `users.json` and `connections.json`, restricted before it becomes
the real file. It holds a service-account password, so:

**No credential reaches a dashboard record, argv, the environment, a commit,
an audit field, or a test fixture.** The service password is read from the
0600 file by the process that binds, and by nothing else. Test profiles use
obviously-fake values pointing at loopback.

Absent file, or a file naming no directory provider, means **local only** —
which is exactly GDASH-4, still working, still fail-closed.

`gdash auth check` is the CLI verb that tests a profile against the live
directory and prints what it resolved: the DN it constructed, whether the bind
succeeded, the raw group values and the names they normalised to. It prints no
password and no attribute record. Without it, the first evidence that a
`group_strategy` is wrong is a dashboard refusing everyone, which is G5-4
happening to an operator instead of to gdash.

### 2.9 `user_*`, now from a directory

The injection mechanism is GDASH-4's and does not change: `user_name`,
`user_email`, `user_groups` come from the resolved identity and are never
merged from the client. What changes is where the identity came from. The
plan's "for real" is this: a visual query binding `:user_groups` filters by
directory groups, server-side, against a shared dataset — design §5's central
claim, with a real organization's groups in it.

## 3. Construction rules

Unchanged from the previous phases, and additionally:

- **`gdash_auth` opens no connection and reads no file.** If it needs one, the
  seam is wrong, and that is a finding rather than a shortcut.
- **Both `ldap.connect` and `ldap.bind` are guarded, everywhere.** The
  platform moved TLS failure into `bind`'s return value (G5-8), which removes
  the trap; `connect` still raises for a configuration error. A raise inside a
  handler kills the worker (PLAT-WEB, let-it-crash), so a directory problem
  must never be able to become a worker problem. Every call site guards both.
- **A directory failure and a wrong password are never the same answer.** The
  module refuses to conflate them (`reason`) and gdash must not undo that:
  `unreachable`, `tls_failed`, `timeout` and `server_error` produce "sign-in
  is unavailable" and an audit line; only `invalid_credentials` produces the
  same refusal a wrong local password does. Naming the directory to the viewer
  is an information leak; telling them their password is wrong when the
  directory is down is worse — it sends them to reset a password that was fine.
- **The refusal a viewer sees is still one refusal.** A username that exists
  in no provider, a wrong password, a disabled account and a directory
  rejection all produce the message GDASH-4 already ships.
- **`ldap.close` on every path**, including the failure paths. It is
  idempotent, which is what makes that safe rather than a second bug.
- **The namespace audit runs from the first commit**, with `gdash_auth` and
  `gdash_auth_ldap` in the probe before they have tests. `search`, `bind`,
  `connect`, `identity` and `groups` are all names worth checking before
  writing them.

## 4. Tests

Tests first, hermetic, scratch-clean, as before. The split is the one G5-7
already established: **the policy layer needs no directory at all**, and the
live runner proves only what a directory can prove.

Hermetic:

- **Escaping.** RFC 4514 DN and RFC 4515 filter, against the characters that
  matter — `*`, `(`, `)`, `\`, NUL, and a leading/trailing space — and a
  username of `*)(uid=*` asserted not to produce a filter that matches
  anything.
- **The chain.** Local wins for a name it holds; the directory is not
  consulted at all for that name; a name local does not hold reaches the
  directory; `known` stops the chain whatever `ok` says.
- **Group normalisation.** `cn=analysts,ou=groups,dc=example,dc=invalid` →
  `analysts` under `rdn`, unchanged under `dn`; an escaped RDN handled; a
  multi-valued attribute yielding several names; **every attribute value read
  as an array**, including a single-valued one (G5-3).
- **Both strategies against a scripted directory** that returns what real
  OpenLDAP returned — `memberOf` absent entirely, and `member=` search
  results — so the G5-4 failure is reproduced in a test that runs with no
  container.
- **Configuration refusals**, in the golden: no `group_strategy`; both
  `user_dn_template` and `user_search`; neither; `user_search` without a
  `base`; an unknown `group_names`; an unknown `kind`; `security` absent.
- **Revalidation**, against a fabricated clock: not revalidated before the
  interval, revalidated after, session destroyed when the user is gone,
  session **kept** when the directory is unreachable.
- **Preview-as**: refused in published mode, refused for a non-editor,
  audited when allowed, and — asserted directly — that it does not change what
  the viewer may open or whether the viewer is an admin.
- **No credential in output**: the `auth check` renderer and every audit line
  asserted not to contain the service password, given a profile that has one.

Live, opt-in, `GDASH_LDAP_TEST=1` against `scripts/ldap_test_directory.sh`:

- Correct bind, wrong password, unknown user, empty password, unreachable
  host — each producing its own `reason` and gdash's own mapping of it.
- Groups resolved by `search` against the seeded `groupOfNames`, and
  `memberof` returning **nothing** against the same directory, which is the
  finding preserved as a test rather than as a paragraph.
- Both `user_dn_template` and `user_search` paths.
- `gdash auth check` against the container, asserted to print the DN and the
  groups and not the password.

## 5. Done means

1. A provider interface exists, `gdash_auth` reaches around it for nothing,
   and its tests pass against a provider gdash does not ship.
2. Local accounts are consulted first and continue to work with no auth file
   present — GDASH-4 unchanged and still green.
3. A user in the directory signs in, and a dashboard gated on a directory
   group is served to them and refused to a directory user who is not in it.
4. The group strategy is named in configuration, both strategies work against
   the real container, and a profile that omits it is refused with a message
   that says what to type.
5. A directory that is down produces "sign-in is unavailable" and an audit
   line, never "wrong password", and never a dead worker.
6. Preview-as works in draft for an editor, is audited, and provably does not
   change authorization.
7. No credential appears in argv, the environment, a record, an audit line, a
   commit or a test fixture.
8. The hermetic suite, the live-Postgres runner and the live-LDAP runner all
   pass; findings recorded; DONE note names everything deliberately not built.

## 6. Deliberately not built

OIDC and SAML (design §10, deferred by name). Kerberos/GSSAPI and SASL — the
module's scope is simple bind and the ask was deliberate. Multiple directory
providers, a provider picker on the login form, and cross-provider username
namespacing. Directory **write** of any kind: no password change, no group
management, no account provisioning; gdash reads a directory and never edits
one. Nested-group expansion — AD's `LDAP_MATCHING_RULE_IN_CHAIN` is a
server-side extension the module does not expose, and walking the tree
client-side is a query amplifier with no bound; a deployment that needs it
names the effective groups. Referral chasing (the module refuses it, correctly).
Connection pooling — one bind per login is the cost, and it is small. Group
caching beyond the session's `revalidate`. Per-folder group defaults (design §8
"optional later"). Rate limiting and lockout, still, and now with a directory
behind it, which makes it GDASH-7's problem rather than nobody's.
