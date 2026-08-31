# GDASH-4 — Sessions, local auth, access enforcement: phase brief

**Status:** IN PROGRESS.
**Narrows:** the GDASH-4 paragraph of `gdash_development_plan.md`.
**Authority:** `gdash_design.md` outranks this brief. The findings of GDASH-0
through GDASH-3 are inputs, not open questions.

Every phase so far has served dashboards to anyone who could reach the port,
behind a single per-dashboard `access: open` opt-in that fails closed and
admits everyone or no one. This phase gives gdash people.

---

## 1. Step-0 verification

Written up in full in `gdash4_findings.md` (G4-1 … G4-8); the short form:

- **The primitives are complete.** `password_hash`/`password_verify` (yescrypt,
  salt and parameters embedded, ~12ms per hash, `password_hash_cost()` to state
  the posture), `crypto.random_token`, `crypto.csrf_token`/`csrf_check` over
  constant-time `bytes_equal`, `req.cookies` in and a response's `cookies`
  array out, `req.scheme` for a conditional `Secure`, and — landed mid-phase —
  `req.form`, so gdash writes no percent-decoder.
- **Nothing above the primitives exists**, for gdash or for the gbasic site:
  no session lifetime, revocation, cookie shape or login flow.
- **The extraction question was put to the gbasic repo and answered: yes, with
  gdash's sequencing.** Build locally first, then extract, because a seam
  designed from one real implementation beats one designed from two
  hypotheticals. Two requirements came back and are built to here rather than
  later: **session-id regeneration on privilege change**, and **the storage
  seam as a record of function values**.
- **`library_collisions()` landed** and found two latent collisions in gdash on
  its first run (G4-6), both since removed. The namespace check is now an audit
  of latent state rather than a watch for a call-triggered warning.

Verified additionally for this phase's own shape: a library's functions can be
stored in a record and called through it (`type(store.put)` is `"function"`),
and `input()` reads a line from stdin even when piped — which is how a password
reaches `gdash user add` without ever appearing in argv or the environment.

## 2. Scope — the narrowing

### 2.1 Local accounts

`/etc/gdash/users.json`, mode 0600, `format: 1`: username → `{ password_hash,
groups, admin, disabled }`. One hash field, because `password_hash` embeds
algorithm, parameters and salt (G4-1) and a second field for any of them would
be a second source of truth.

Managed by CLI, since v1 authoring is the file and there is no admin UI:
`gdash user add|passwd|groups|disable|enable|list`. **The password is read from
stdin, never from argv and never from the environment** — argv is world-visible
in `ps`, and an environment variable outlives the command that set it.

### 2.2 Bootstrap

A server with no users at all is not usable and must not be open. First-admin
creation is `gdash user add <name> --admin` run by whoever installed it; the
server refuses to start serving authenticated routes with an empty user file
only in the sense that nobody can log in — it does **not** fall open. There is
no bootstrap token, no first-run web wizard, and no default account: each is a
credential that exists before anyone chose it.

### 2.3 Sessions

Server-side, one small JSON file per session under `/run/gdash/sessions/`.
Files rather than a database, because workers share no in-memory state
(design §5) and the filesystem is how every other global fact in gdash already
travels; one file per session because that is a store with no shared writer and
therefore no lock. `/run` is the FHS home for runtime state and is cleared on
reboot, which is the correct lifetime for a session.

- The id is `crypto.random_token(32)`. It is base64url — `-` and `_`, no `/`
  and no `.` — which is what makes it usable as a filename **after** it is
  validated, not because it is trusted.
- The cookie is `HttpOnly`, `SameSite=Lax`, `Path=/`, bounded max age, and
  `Secure` **when `req.scheme` is https** — conditional because design §6
  expects intranet deployments where TLS is recommended rather than required,
  and a hardcoded `Secure` would silently break login on exactly those.
- **The id is regenerated on every privilege change** — login and logout. The
  id a viewer held before authenticating is never the id they hold after. This
  is the session-fixation defence, and it is here because the platform review
  named it as the rule hand-rolled session code most often omits.
- Expiry is absolute and idle, both bounded. An expired session is
  indistinguishable from no session, at one place in the code.

### 2.4 The storage seam

`gdash_session` owns the rules; it never touches a file. It takes a store —
**a record of function values** — with `put`, `get`, `drop`, `sweep`, and a
`find_user`. `gdash_users` supplies the file-backed implementation.

This is the shape the extraction ask proposed and the platform accepted, built
now so that extraction later is a move rather than a rewrite. It is also how
the tests get a store that never touches a disk.

### 2.5 CSRF

`crypto.csrf_token(secret, session_id)`, checked on **every state-changing
route**: login, logout, param publication, refresh, publish, rollback. The
secret is server-level, generated at first start into `/etc/gdash/secret`
(0600) — a fixed secret in the source would make every deployment's tokens
forgeable by anyone who read the source.

A GET is never state-changing. If that stops being true, the route is wrong,
not the check.

### 2.6 Authorization: coarse, per-dashboard, fail-closed

The record names `view_groups` and `edit_groups` (design §8). Resolution order
for a request:

1. `access: open` → served to anyone, authenticated or not. **Per-dashboard
   opt-in, never a server default** (design §8), and this phase keeps it
   working exactly as it does today, because a genuinely public dashboard is a
   real thing an organization wants.
2. Otherwise the viewer must be authenticated **and** in one of
   `view_groups` — or be an admin.
3. Anything else is refused. A record naming no groups and no `access` is
   viewable by admins only: a half-configured dashboard fails closed.

`edit_groups` gates the state-changing routes this build has — publish,
rollback, refresh. Draft editing is still file editing and is governed by the
filesystem.

### 2.7 `user_*`, and why it is in this phase

Design §2 reserves `user_email`, `user_name`, `user_groups`, injected by the
server from the authenticated identity: "personalization is parameter binding,
not a feature". The plan puts "`user_*` param injection **for real**" in
GDASH-5, alongside LDAP.

It is here, and that is not widening: GDASH-5 makes them real by sourcing them
from a **directory**; the injection mechanism is the same either way and it is
this phase's identity that fills it. Without it, design §5's central security
claim — that user-filtered dashboards over a shared dataset are genuinely
secure because the trust boundary is the server — has nothing to filter by and
cannot be tested at all. A phase that builds identity and cannot demonstrate it
reaching a query has built half of something.

`user_*` are injected, never accepted from the client. A query parameter named
`user_email` is ignored, and that is tested.

## 3. Construction rules

Unchanged from the previous phases, and additionally:

- **`gdash_session` touches no file.** If it needs one, the seam is wrong and
  that is a finding, not a shortcut.
- **A password never enters argv, the environment, a log line, a record, an
  audit field, or a test fixture.** Test users get obviously-fake passwords and
  the hashes are computed, never pasted.
- **Every refusal is the same refusal.** A wrong username and a wrong password
  produce one message and one timing path; naming which half was wrong is a
  user-enumeration oracle.
- **The namespace audit runs from the first commit**, with `gdash_session` and
  `gdash_users` in the probe before they have tests.

## 4. Tests

Tests first, hermetic, scratch-clean, as before. Additionally:

- **A store double**: the seam is exercised with an in-memory store, which is
  the proof that `gdash_session` really is storage-free.
- **Session-id regeneration**, asserted on login and on logout — the id before
  is never the id after.
- **Expiry**, absolute and idle, against a fabricated clock. Nothing sleeps.
- **CSRF**: a state-changing request without a token, with another session's
  token, and with a valid one.
- **Authorization matrix**: open / in-group / out-of-group / unauthenticated /
  admin, against view and edit, including a record naming no groups.
- **`user_*` injection**, including that a client-supplied `user_email` is
  ignored rather than honoured.
- **Password handling**: verify succeeds, wrong password fails with the same
  message as an unknown user, a disabled account cannot log in, and a corrupt
  hash fails closed.
- The end-to-end run logs in over HTTP, holds a cookie, is refused without one,
  and sees a dashboard filtered by its own identity.

## 5. Done means

1. Local accounts exist, are managed from the CLI, and no password reaches
   argv or the environment.
2. Login and logout work over HTTP with a server-side session, and the session
   id changes at both.
3. CSRF is enforced on every state-changing route.
4. A dashboard is served to a viewer in its `view_groups`, refused to one who
   is not, and still served to anyone when `access: open` — with the
   half-configured case failing closed.
5. A visual query binding `user_email` gets the authenticated identity, and
   cannot be made to get anything else by the client.
6. `gdash_session` passes its tests against a store that is not a filesystem.
7. The hermetic suite and the live-Postgres runner both pass; findings
   recorded; DONE note names everything deliberately not built.

## 6. Deliberately not built

LDAP and any directory provider (GDASH-5), and with them preview-as. OIDC and
SAML (design §10). Password policy — length and complexity are a deployment's
opinion, and inventing one here would be inventing it for everyone. Password
reset, email of any kind, account self-service, and registration: this is an
intranet product whose accounts are provisioned by whoever runs it. Rate
limiting and lockout on failed login. A user-management UI. Folder-level
group defaults (design §8 names them as "optional later"). Remember-me beyond
the session cookie's bounded age. Per-visual or per-row authorization — design
§8's authorization is coarse and per-dashboard on purpose, and row-level
filtering is what `user_*` in a query already is.
