# GDASH-4 — Findings

**Status:** phase opening; step-0 complete.
**Platform:** gBASIC `e8b3549`. Everything here was probed against the real
binary, not read out of the design.

Platform items are findings for this report and candidates for gbasic's
DOGFOOD.md, filed only through that repo's own process (CLAUDE.md).

---

## G4-1 — password hashing is already right, and already chosen for us

`password_hash(p)` / `password_verify(p, h)` exist and do the correct thing.
Measured:

- Output is libxcrypt yescrypt: `$y$j9T$…`, 73 characters, algorithm,
  parameters and salt all embedded in the string, so a user record stores one
  field and nothing else.
- Two hashes of the same password differ — per-password salt, verified rather
  than assumed.
- `password_verify` against a string that is not a hash returns `false`; it
  does not raise. So a corrupted user record fails closed by itself.

Design §8 says "password hashing via the platform's `pbkdf2`/`scrypt` with
per-password salt + algorithm metadata". `password_hash` supersedes that and is
better: yescrypt is a memory-hard modern KDF and the metadata handling is the
platform's rather than gdash's. **This is a design edit owed to the
maintainer**, not a contradiction to work around — the design named the
mechanism it had; a better one shipped.

**The number worth knowing: a hash costs ~12ms and a verify ~9.5ms.** That is
comfortable in a request handler — a login pins a worker for a hundredth of a
second — but it is *fast* for a password KDF, and gdash cannot tune it: the
cost parameters are libxcrypt's preferred defaults and the builtin takes no
options. An attacker holding `users.json` can try on the order of 10^5
candidates per second per core. For an intranet product with a small admin
population that is an acceptable posture; it is not one to be silent about,
and it is the reason `users.json` is 0600 in design §6 rather than merely
tidy. A cost parameter would be a reasonable future platform ask.

## G4-2 — CSRF and session ids need nothing built

`crypto.csrf_token(secret, session)` is an HMAC-SHA256 over the session id,
`crypto.csrf_check` compares with `bytes_equal` (constant time, and
`has_builtin("bytes_equal")` is true), and `crypto.random_token(32)` yields 43
characters of base64url from cryptographically secure bytes. All verified,
including that a token minted for one session fails the check for another.

The session id being base64url matters downstream: it contains `-` and `_` and
no `/` or `.`, which is what makes it safe to use as a filename (§2 of the
brief) once validated.

## G4-3 — there is no form-body decoder

`req` carries `id, method, path, query, headers, cookies, body, scheme,
remote_ip, remote_port, timestamp, server, params`. `req.query` is
percent-decoded for you. **`req.body` is raw** — a POST of
`user=ada&pass=x` arrives as exactly that string, and there is no `req.form`.

So a login form's body is the application's to parse: split on `&`, split on
`=`, percent-decode both halves, and decide what a duplicate key means. That
is thirty lines, and every gBASIC application that ever accepts a form will
write the same thirty lines. It is therefore part of the extraction question
(G4-4) rather than a nuisance to absorb quietly.

Not a defect: the platform decodes the query string because a route needs it,
and declines to guess a body's encoding, which is defensible. It is a gap in
what a web application can assume.

## G4-4 — there is no session store, and the second consumer's is Postgres

Nothing in the stdlib holds sessions. `persist.bas` is atomic JSON writes and
`crypto.bas` is primitives; between them there is no session lifetime, no
revocation, no cookie shape, no login flow.

Design §8 names extraction into a shared stdlib component as a candidate, with
**two consumers as the promotion bar** — gdash first, the gbasic site second.
Reading the site's own plan (`docs/gbasic_site_auth_plan.md`) turns that from a
formality into a real design question: the site's users and sessions live in
**Postgres**, with `gbasic_site_users` and `gbasic_site_sessions` tables
specified down to their columns. gdash cannot require a database service — that
dependency-free deployment is close to the whole pitch (design §3).

So the two consumers agree on every rule and disagree on every byte of storage.
A shared component is still the right answer, but only if it is drawn with a
**storage seam**: the library owns id generation, cookie formatting, CSRF
binding, expiry and revocation semantics, and the login/logout flow; the
consumer owns the four or five operations that put a session somewhere. That
is the shape the ask proposes (`gdash4_platform_ask_session.md`).

Per the development plan, this phase does not block on the answer: gdash builds
its own, shaped so that extraction is a move rather than a rewrite.

## G4-5 — `req.scheme` exists, so `Secure` can be conditional

Verified: `req.scheme` is `"http"` over a plain connection, and
`web.trust_proxy` rewrites it from `X-Forwarded-Proto` behind a proxy that has
been named as trusted. So the session cookie can carry `Secure` exactly when
the connection is HTTPS, rather than being hardcoded either way.

This matters more for gdash than for a public site: design §6 says intranet
deployment is typical and TLS is recommended rather than hard-required. A
hardcoded `Secure` would silently break login on the deployments the design
expects; omitting it always would weaken the ones that did the right thing.

## G4-6 — a real library-vs-library name collision produced NO warning

`persist.bas` defines `ensure_dir`. So does `gdash_paths`. Loading both, in
either order, produces **no override warning at all** — verified twice, and
both libraries genuinely load (a `persist.read_status` call answers, so this is
not a `load` that quietly did nothing).

That contradicts F6, where `gdash_paths.resolve` shadowing `web.resolve` *did*
warn, with the message `eval.c:6843` emits for exactly this case: *"function
'%s' from library '%s' overrides function from library '%s'"*. Same shape, one
warns and one does not. I could not determine the mechanism from outside and
am not going to guess at it — guessing at a cause instead of reading it is how
F5 went wrong.

**This matters to gdash specifically.** GDASH-2 built a namespace sweep
(G2-8) whose entire assertion is "the interpreter said nothing about an
override". Here is a collision it would not report. The sweep is still worth
having — it caught `gdash_diff.lines` on its first run (G3-1) — but it is now
known to be a partial check, and this finding is the note that keeps anyone
from reading a green sweep as proof.

gdash does not load `persist` and will not. Practical rule for this phase and
after: a new public name is checked by **reading** the stdlib, with the sweep
as a backstop rather than the authority.

## G4-7 — `load <name>` reaches the INSTALLED stdlib, not the repo's

`load persist` resolved to `/usr/local/share/gbasic/stdlib/persist.bas`. The
installed tree and the repo's `stdlib/` happen to be identical today, and that
is luck rather than structure — the gbasic repo is under active development in
a sibling checkout, and `make install` is what synchronises them.

gdash already loads `chart` by explicit relative path into the repo. Everything
else — `sqlite`, `crypto`, `web` — comes from whatever is installed. So gdash's
behaviour depends on two different trees at once, and a platform fix that has
landed in the repo does not reach gdash until it is installed.

Recorded rather than acted on: pinning every load to the repo would make an
*installed* gdash unbuildable, which is worse. The right note is the one for
whoever next reports "gbasic fixed it and gdash still misbehaves": check
`/usr/local/share/gbasic/stdlib` before reopening the finding.
