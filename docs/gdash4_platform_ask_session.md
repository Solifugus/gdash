# Cross-repo ask — a session/auth component with a storage seam

**Raised by:** gdash, at GDASH-4's step-0.
**Ruled by:** the gbasic repo, through its own process.
**Status:** open. gdash is not blocked on it and is building its own, shaped so
that extraction is a move rather than a rewrite (development plan, GDASH-4).

---

## Why this is being asked now

gdash's design §8 names session/auth extraction as a candidate for a shared
stdlib component, "with gdash as first consumer and the gbasic site as second —
two consumers is the promotion bar". GDASH-4 is where gdash becomes that first
consumer, so the bar is now testable rather than hypothetical, and the
development plan says to open the question **before** building.

Step-0 established what does and does not exist (`gdash4_findings.md`):

- **Primitives are complete.** `password_hash`/`password_verify` (yescrypt,
  salt and parameters embedded), `crypto.random_token`, `crypto.csrf_token` /
  `csrf_check` over `bytes_equal`, cookie parsing on `req.cookies` and emission
  through a response's `cookies` array, and `req.scheme` for a conditional
  `Secure`. None of this needs anything.
- **Everything above the primitives is missing.** No session lifetime, no
  revocation, no login flow, no cookie shape, and no form-body decoder
  (`req.body` is raw; there is no `req.form`).

So both consumers will write the same second layer, and the question is whether
they write it once.

## The thing that makes it a design question rather than a formality

The two consumers agree on every **rule** and disagree on every **byte of
storage**.

`docs/gbasic_site_auth_plan.md` specifies the site's storage down to its
columns — `gbasic_site_users` and `gbasic_site_sessions`, in **Postgres**, with
`references … on delete cascade`.

gdash cannot require a database service. Design §3 rules SQLite for the staging
store precisely because "for a product whose pitch is install-in-minutes, the
dependency-free deployment is close to the whole pitch". gdash's sessions are
going to be small files under `/run/gdash/` and its users a 0600 JSON file
under `/etc/gdash/` — shared-nothing workers coordinating through the
filesystem, which is how every other global fact in gdash already travels.

A component that assumes either storage is useless to the other consumer. A
component that abstracts storage is useful to both — and to the third consumer,
who has not asked yet.

## The shape proposed

A library that owns the **rules** and calls out for the **bytes**. The caller
supplies a store: a record of functions, which gBASIC has as first-class
values.

The library would own:

- session id minting (`crypto.random_token`, not a predictable string)
- the cookie: `HttpOnly`, `SameSite`, `Path`, conditional `Secure` from
  `req.scheme`, a bounded max age
- CSRF token derivation bound to the session id, and the check
- expiry and explicit revocation semantics, including what a request with an
  expired session sees (which is the same thing as no session, and saying so
  once is worth more than saying it twice)
- the login and logout flows as functions over the store
- **form-body decoding**, because `req.body` is raw and both consumers need it

The caller would own, as four or five functions:

- `put(session)` / `get(id)` / `drop(id)` / `sweep(before)`
- `find_user(username)` returning at least `{ id, password_hash, disabled }`

The gbasic site implements those against Postgres. gdash implements them
against files. Neither needs to know what the other did.

## What is deliberately not being asked for

- **No identity provider abstraction.** LDAP is gdash's GDASH-5 and belongs to
  gdash until something else wants it.
- **No authorization model.** gdash's authorization is per-dashboard groups and
  is entirely gdash's business. Only authentication and session mechanics are
  general.
- **No user management UI or bootstrap flow.** How a first admin comes to exist
  differs per product; gdash's is environment-driven at first start.
- **No password policy.** Length and complexity rules are a deployment's
  opinion.

## If the answer is no

That is a fine answer and the plan already provides for it: gdash builds
`gdash_session` and `gdash_users` locally, with the storage calls already
isolated behind the same four or five functions described above. Extraction
later becomes moving a file and deleting a seam, not a rewrite.

The one thing worth having either way is a **form-body decoder**, wherever it
lives. It is thirty lines, every web application needs it, and thirty lines
written independently by every application is thirty lines of independently
wrong percent-decoding.

## A second, much smaller finding worth filing separately

While probing, a real library-vs-library name collision produced **no override
warning**: `persist.bas` and `gdash_paths` both define `ensure_dir`, and
loading both in either order says nothing — while `gdash_paths.resolve`
shadowing `web.resolve` did warn, which is the message `eval.c:6843` emits for
this exact case. Same shape, different outcome. Recorded as G4-6; not diagnosed
from outside, because guessing at a cause rather than reading it is how gdash's
F5 went wrong.

This matters beyond gdash: a warning that fires for some collisions and not
others is worse than one that fires for all of them, because it invites exactly
the trust that gdash's own namespace sweep placed in it.

---

## Prompt to send to the gBASIC session

> gdash has reached GDASH-4 (sessions, local auth, access enforcement), and its
> design §8 named session/auth extraction into a shared stdlib component as a
> candidate — with gdash as first consumer, the gbasic site as second, and two
> consumers as the promotion bar. gdash is now that first consumer, so the
> question is live. Its development plan says to raise it with you before
> building.
>
> Step-0 findings from gdash, all probed against `e8b3549` rather than read out
> of a design:
>
> - The primitives are complete and correct. `password_hash`/`password_verify`
>   give yescrypt (`$y$j9T$…`, 73 chars, salt and parameters embedded), two
>   hashes of one password differ, and verifying against a non-hash returns
>   false rather than raising. `crypto.random_token(32)`, `crypto.csrf_token`
>   and `csrf_check` over `bytes_equal` all behave. `req.cookies` parses and a
>   response's `cookies` array emits. `req.scheme` is there, so `Secure` can be
>   conditional — which gdash needs, since intranet-without-TLS is a deployment
>   its design expects.
> - Everything above the primitives is missing for both consumers: session
>   lifetime, revocation, cookie shape, the login flow, and a form-body
>   decoder. `req.body` is raw and there is no `req.form`, so a login form is
>   the application's to parse.
>
> The reason this is a design question rather than a formality: the two
> consumers agree on every rule and disagree on every byte of storage. Your site
> auth plan specifies `gbasic_site_users` and `gbasic_site_sessions` in
> Postgres, down to the columns. gdash cannot require a database service —
> design §3 rules SQLite for staging precisely because dependency-free
> deployment is close to gdash's whole pitch — so its sessions are files under
> `/run/gdash/` and its users a 0600 JSON file.
>
> The proposal is therefore a component with a storage seam. The library owns
> the rules: id minting, the cookie (HttpOnly/SameSite/Path/conditional
> Secure/bounded age), CSRF bound to the session id, expiry and revocation
> semantics, the login and logout flows, and form-body decoding. The caller
> owns the bytes as four or five functions — `put`/`get`/`drop`/`sweep` and
> `find_user` returning at least `{ id, password_hash, disabled }`. Your site
> implements those against Postgres; gdash implements them against files.
>
> Deliberately not asked for: an identity-provider abstraction (LDAP is
> gdash's GDASH-5), any authorization model (gdash's is per-dashboard groups
> and is its own business), user-management or bootstrap flows, and password
> policy.
>
> If the answer is no, that is fine and gdash is not blocked: it builds
> `gdash_session` and `gdash_users` locally with the storage calls already
> isolated behind those same functions, so extraction later is a move rather
> than a rewrite. The one piece worth having wherever it lives is the form-body
> decoder — thirty lines that every web application needs, and thirty lines of
> independently wrong percent-decoding if each writes its own.
>
> Separately, and much smaller: a real library-vs-library name collision
> produced no override warning. `persist.bas` and `gdash_paths` both define
> `ensure_dir`; loading both in either order says nothing, and both really load
> (a `persist.read_status` call answers). But `gdash_paths.resolve` shadowing
> `web.resolve` *did* warn — the `eval.c:6843` message for exactly this case.
> Same shape, different outcome. I have not diagnosed it from outside and would
> rather not guess; gdash's F5 went wrong by inferring instead of reading. It
> matters beyond gdash because gdash built a namespace sweep whose whole
> assertion is "the interpreter said nothing about an override", and this is a
> collision it would not report.
