# GDASH-4 — Findings

**Status:** phase opening; step-0 complete.
**Platform:** gBASIC `79e8939` (step-0 was run against `e8b3549`; the
platform answered mid-phase and three items below are updated in place).
Everything here was probed against the real binary, not read out of the design.

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

**`password_hash_cost()` now reports this rather than leaving it to be
measured.** It returns `{ ms, prefix }` by performing one real hash — here
`{ ms: 11.3, prefix: "$y$j9T$" }` — where `prefix` is the parameter field
alone, so two deployments can compare what they are actually running. It does
not let gdash tune the cost; it lets gdash *state* its posture instead of
assuming it. It costs a hash, so it is a diagnostic and not a per-request call.

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

## G4-3 — there was no form-body decoder; now there is

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

**Closed by the platform.** `req.form` now sits beside `req.cookies`, decoding
`application/x-www-form-urlencoded` through the same parser as the query
string — `+` is a space, and `pass=p%40ss%26word` yields `p@ss&word` with the
encoded separator intact. Only a form content type is decoded: JSON or
multipart yields an empty record rather than a field named `{"a` holding `1`,
which is the failure a naive splitter would produce. Multipart and file upload
are deliberately not handled.

So gdash writes no percent-decoder, and the thirty lines that every gBASIC web
application would otherwise have written independently — and got subtly
differently wrong — are the platform's. This was the piece of the extraction
ask worth having wherever it lived.

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

## G4-6 — the override warning is call-triggered, so it cannot be an audit

`persist.bas` defines `ensure_dir`. So does `gdash_paths`. Loading both, in
either order, produced **no override warning at all** — verified twice, with
both libraries genuinely loading. That contradicted F6, where
`gdash_paths.resolve` shadowing `web.resolve` *did* warn, with the message
`eval.c:6843` emits for exactly this case. Same shape, one warned and one did
not. I recorded the observation and refused to guess at the cause, because
guessing instead of reading is how F5 went wrong.

**Diagnosed by the platform, and the answer is the useful one.** The warning
lives in the *unqualified-lookup* path, not at registration. It is
call-triggered: two libraries sharing a name are silent for as long as every
call is qualified, and it fires the first time a bare name has to choose. So
`persist`/`gdash_paths` was silent because nothing called `ensure_dir` bare,
and `resolve` warned because something called it bare. One code path, two
outcomes, no inconsistency.

The conclusion stands and is now in gbasic's `docs/ai/UNLEARN.md`: **the
warning cannot serve as a namespace audit**, and a sweep resting on it is a
partial check. GDASH-2's sweep was exactly such a sweep.

**`library_collisions()` now exists** — every public name defined by more than
one loaded library, reported as `[{ name, libraries }]`, latent state and all,
before anyone writes the call that makes it live.

Wired in immediately, and it found two collisions in gdash that three phases of
stderr-watching never saw:

- **`page` — `chart` and `gdash_app`.** `gdash_app.page` was the main page
  handler. Nothing inside `chart` calls `page` bare today, so nothing was
  broken; but this is F6's exact shape, sitting in the most consequential
  function in the application, waiting for either side to write one unqualified
  call. Renamed to `dashboard_page`.
- **`_html_escape` — `gdash_render` and `gdash_app`.** Two byte-identical
  copies, which is how one of them ends up missing a case. Collapsed to one
  public `gdash_render.html_escape`.

Neither would have been reported by the old sweep, and neither had symptoms.
That is the whole argument for a latent-state audit over a call-triggered
warning, demonstrated on the first run.

**Do not assert the list is empty.** The stdlib itself carries benign shared
names — loading `dates` and `frame` legitimately reports `select` — so the
audit takes an allowlist, and a name lands there with a sentence saying why the
collision is harmless. gdash's allowlist is currently empty, which is a fact
about gdash rather than a target.

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

## G4-8 — the extraction is approved, with the sequencing gdash proposed

The gbasic repo's answer to `gdash4_platform_ask_session.md`: **yes**, build
`gdash_session` and `gdash_users` locally first, then extract. A seam designed
from one real implementation beats one designed from two hypotheticals, and
gdash's storage calls are already isolated behind four or five functions, so
extraction stays a move rather than a rewrite.

Two requirements came back for the eventual shared component, both of which
gdash builds to now rather than later:

- **Session-id regeneration on privilege change.** The session-fixation
  defence: the id a viewer held before authenticating must not be the id they
  hold after. It was not in the ask's list of what the library would own, and
  it is named as the most commonly omitted rule in hand-rolled session code —
  which is the argument for a shared component owning it, so that nobody has to
  remember. gdash regenerates on login and on logout.
- **The storage seam is a record of function values** — `{ put: files.put,
  get: files.get, … }` — rather than a record carrying state and functions
  together, invoked as a method, which would drag private wiring into the
  caller. Worth recording that this only became expressible in August, when
  `lib.fn` became a first-class function value: the clean shape is newer than
  the problem.

---

## G4-9 — the namespace audit found F6 again, in a module written after F6

`library_collisions()` was wired in on the day it landed, and on the first run
against this phase's new modules it reported:

- **`resolve` — `web` and `gdash_session`.** That is **F6 exactly**: the
  finding that cost an afternoon of GDASH-0, where `gdash_paths.resolve`
  shadowed `web.resolve`, every working route broke while trivial ones
  answered, and the only signal was a stderr warning nobody was reading. I
  wrote it again, in a module whose whole subject is security, four phases
  after writing the finding down. It is `gdash_session.active` now, with the
  reason in a comment above it.
- **`load_file` — `gdash_record` and `gdash_users`.**
- **`_restrict` — `gdash_refresh` and `gdash_users`.** Two copies of a
  `chmod 600`, which is two places for one of them to be forgotten. Now one
  `gdash_paths.restrict`.

Three more followed during the phase, each caught on the run after the code
was written: `gdash_users.find` and `remove` shadowing built-ins, and
`gdash_app.csrf_ok` colliding with `gdash_session.csrf_ok`.

None had symptoms. None would have been reported by watching stderr, because
every call was qualified. The audit is the reason this phase did not ship a
second F6, and the honest conclusion is that a naming discipline held by
memory does not hold — mine has now failed at it four times in a row.

## G4-10 — a pre-login session is a real session, and the code did not think so

The end-to-end run found one genuine bug, and it is worth recording because
the mistake is a category error rather than a slip.

`viewer_of` resolved a session, looked its user up, and destroyed the session
if the user did not resolve — reasonable, since an account removed or disabled
while a session lived should take the session with it. But a **pre-login**
session has no user at all: it exists so the login form's CSRF token has
something to be bound to. Both cases reached the same branch, so every visit
to `/login` minted a session and then destroyed it on the next request,
carrying the form's token with it. Signing in was impossible.

The fix is one branch: an empty user is a pre-login session and is kept; a
non-empty user that no longer resolves is an account that went away and the
session goes with it. Two different facts that had been written as one.

Recorded because it is the shape of bug this whole phase is most exposed to:
"not signed in" and "has no session" are the same thing to every caller, which
is exactly why the code that distinguishes them has to do it deliberately.

## G4-11 — an unauthenticated refusal is a 404, not a 403

Not a defect; a ruling, made here and worth writing down because it looks like
a mistake to anyone reading the route table.

A viewer who is not signed in and asks for a dashboard they may not see gets
**404**, indistinguishable from a dashboard that does not exist. On an
intranet — design §1's expected deployment — the existence of a dashboard
called `layoffs-q3` is itself information, and a 403 confirms it to anyone who
can reach the port.

A viewer who **is** signed in and simply lacks the group gets **403**. For
them the dashboard's existence is not the secret; their access to it is, and a
404 would send them to an administrator to report a bug that is not one.

The diff endpoint follows the same rule, because a snapshot is a version of a
dashboard and whoever may not see one may not see the other.

## G4-12 — F6 is fixed at the root, and several findings above are now history

The platform changed the resolution rule: **inside a library body, an
unqualified name resolves to that library's own function first**
(gbasic `d08409f`). Verified rather than taken on report:

- **The F6 scenario itself no longer breaks anything.** A library defining
  `resolve` alongside a `server` block — the exact shape that broke every
  working route in GDASH-0 while trivial ones answered — now dispatches
  correctly (`/hello/{who}` → `hi ada`), and the shadowing library's own
  `resolve` is still reachable through its prefix.
- **The minimal repro inverts.** `liba.work()` calling its own bare `helper`
  returned `libb`'s answer before; it returns `liba`'s now.
- **The cross-library fallback is preserved.** A library calling another
  library's function by a bare name it never declared still resolves, so
  nothing that depended on the old reach is cut off.
- **gdash is green on it**: 19 suites, 476 in-process assertions plus 128
  end-to-end, live Postgres 8/8, no code changes.

**What this retires.** F6 (GDASH-0), G1-2, G2-8, G4-6 and G4-9 are all the same
hazard seen from five angles, and the hazard is gone in its damaging form. The
renames it forced stay — `gdash_paths.roles`, `gdash_session.active`,
`gdash_app.dashboard_page`, `gdash_render.html_escape` — because renaming them
back is churn with no benefit, and several read better than what they replaced.

**What it does not retire.** `library_collisions()` is still worth running:
two libraries defining one name is still ambiguous for a *caller* writing the
bare name outside either of them, and the audit is the only thing that reports
it. gdash's allowlist stays empty.

**One discrepancy to report back.** The fix reached the built-in case too, and
the warning text did not follow it. A library defining `lines` (a built-in)
and calling it bare from its own body now gets **its own** function — verified,
`blib.count_them` returns 2 rather than raising `lines expects a file
reference` — while the warning at that definition still says *"unqualified
calls use the built-in"*. From outside the library the built-in does still win,
so the sentence is true of one call site and false of the one the warning
points at. Not a defect in behaviour; a stale message on a line that now means
something else.

**All three follow-ups resolved and verified** (gbasic `417f061`, `389df3a`):

- The text now names both sides of the boundary and the escape hatch:
  *"inside 'blib' unqualified calls use this function, outside it they use the
  built-in, and 'blib.lines' is explicit either way."* Accurate wherever it is
  read, which the old sentence was not.
- The built-in half was **ruled intended**, and the severity dropped from
  `warning:` to `note:` — a rule rather than a hazard. That is the right call
  and it is now the message's own claim rather than something a reader has to
  infer from behaviour.
- The location is correct: physical line 4 in a file whose function is on line
  4, and physical line 7 in the file whose function is on line 7. Both
  previously reported line 2.

One consequence worth recording: **a library-vs-library collision is now
silent**, and correctly so — neither library is harmed. gdash's stderr sweep
therefore catches only built-in shadowing now, and `library_collisions()` is
the only thing that sees the other case at all. Both halves of the check are
still earning their place; what each covers has changed underneath them.

## G4-13 — every currency, and what the lookup costs

GDASH-1 shipped eight currencies as literal branches, because `{USD}=` needs a
literal code; its DONE note called widening "mechanical, wanting generation
rather than typing". `money.of(code, text)` takes the code as a **value**, so
it wants neither. Three enumerations collapsed at once:

- `to_money`'s eight-branch chain became one call.
- `supported_currencies()` now comes from `money.currencies()` — 178 codes,
  and a list that cannot drift out of date the next time a currency
  redenominates.
- `minor_places()` reads the exponent from the same source instead of
  hardcoding JPY 0, KWD 3, everything else 2. BHD now renders at three places
  without anyone having thought about BHD.

The range refusal improved with it. The ceiling is an int64 at exponent + 4
guard digits, so it **moves with the currency** — USD stops at
`9,223,372,036,854.77`, KWD at `922,337,203,685.477`, JPY at
`922,337,203,685,477`. The old message quoted USD's number for every currency,
which was wrong for two of the eight it supported. It now names the ceiling of
the currency that actually refused.

**The cost, measured rather than assumed.** `money.currencies()` builds all 178
records per call: 10,000 lookups take **0.75s early in the list and 0.81s at
the end**, so the scan is not what costs — the array build is. That is ~80µs
per formatted money value.

Left as it is, deliberately. The reference dashboard renders in ~30ms end to
end. A hundred-row table pays ~8ms; a ten-thousand-row one would pay most of a
second, and GDASH-1 already recorded that a table paginates nothing. The fix
if it ever matters is to resolve the exponent once per visual — `gdash_render`
already computes the scale and currency once — rather than once per cell. That
is a change to the format API's shape, and making it now would be inventing a
problem the reference record does not have.
