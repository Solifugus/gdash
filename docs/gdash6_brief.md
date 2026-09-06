# GDASH-6 — Hardening: phase brief

**Status:** COMPLETE. All eight §5 criteria met; at the review boundary.
Findings in `gdash6_findings.md` (G6-1 … G6-17); DONE note in §7. Step-0
passed, which was not the expected outcome.
**Narrows:** the GDASH-6 paragraph of `gdash_development_plan.md`, a phase
inserted after GDASH-5 rather than planned from the start.
**Authority:** `gdash_design.md` outranks this brief. The findings of GDASH-0
through GDASH-5 are inputs, not open questions.

Five phases built capability. This one buys confidence in it, and adds no
feature at all. That is the whole point: a phase whose deliverable is
capability can always borrow against its tests, and five of them in a row have.

---

## 1. Step-0 verification

Full write-up in `gdash6_findings.md`. The short form:

- **Design §5's shared-nothing claim is true, and nobody had ever checked**
  (G6-1). Run with four workers: sessions seen 30/30 across them, one CSRF
  token, eight concurrent renders all 200, and **four concurrent SSE streams on
  four workers all observed a refresh performed by a fifth process** that
  shares nothing with any of them but a directory. The architecture's central
  mechanism is now observed rather than intended.
- **The readiness contract changes with `workers: N`** (G6-2). `serve` becomes
  the supervisor, prints `PORT <n>` itself, and does not return until drain, so
  gdash's own `listening` line never appears. Every readiness check gdash
  ships greps for `listening`.
- **`secret_of` is the only durable write in gdash that is not atomic**
  (G6-3) — in the one module where every other write is, and in
  security-relevant code.
- **`web.dispatch` runs a full request with no socket** and gdash has never
  used it (G6-4), but a `server` block cannot be loaded from another file, so
  the *route table* stays end-to-end's job. The *handlers* do not: they are
  plain functions taking a `req` record and always were.
- **133 end-to-end assertions are substring matches, and three have already
  lied** (G6-6) — each caught only because it failed in the direction that
  shows. The other direction is silent.

## 2. Scope

### 2.1 Multi-worker, as a supported and tested configuration

Step-0 proved it works; this makes it something gdash keeps working.

- The server block declares a worker count that an operator can change, and
  the readiness line is correct in **both** shapes rather than only at
  `workers: 1`.
- Both live runners (`run_e2e.sh`, `run_ldap.sh`) gain a worker-count knob and
  the e2e runs its spine at least once with more than one, so a regression in
  the shared-nothing property fails a test rather than a deployment.
- The four properties G6-1 checked by hand become assertions.

### 2.2 `gdash_app`, tested in process

The largest module in the product, holding every authorization decision, gets
the hermetic tests its own file header has promised since GDASH-0.

Handlers take a synthetic `req` — `{ method, path, params, query, form,
cookies, headers, scheme }` — and return a response record. The tests assert on
**the record**: `status`, `headers`, `cookies`, and only then on body content.
That is the difference from `curl`: a 403 is a number, not a phrase that might
also be in a stylesheet.

The authorization matrix in particular becomes **a table**, not forty curl
invocations: {open, group-gated, no-groups} × {anonymous, member, non-member,
editor, admin} × {view, edit}, with the 404-vs-403 disclosure rule asserted
per cell. A rule that fits in a table should be tested as one; written out
long-hand, a missing row is invisible.

### 2.3 A seam under the LDAP wire

`gdash_auth_ldap` is 701 lines and roughly 400 of them — `find_user`,
`groups_for`, `open_service`, `explain`, and every failure branch — run **only
under `GDASH_LDAP_TEST=1`**. From a clean checkout with no container, that is
authentication code with no coverage at all.

The fix is the move this codebase has already made twice: put the four `ldap`
calls behind a record of function values, exactly as `gdash_session` took a
store and `gdash_auth` took a provider. The live module is one implementation;
a scripted directory in `tests/` is another.

This is worth more than the coverage number, because a scripted directory can
return what a healthy container will not: a search that succeeds with zero
entries, an entry whose `dn` disagrees with the filter that found it, an
attribute that is present in one search and absent in the next, a group DN with
an escaped comma, `server_error` at exactly the third call. Those are the
branches that exist precisely because a real directory might misbehave, and
they have never been executed.

**The live runner does not shrink.** It keeps every assertion it has: the seam
proves gdash's logic, and only a real server proves the seam matches reality.

### 2.4 Concurrency, produced rather than assumed

Three races exist in the code and none has ever been run:

- **The refresh lock.** `gdash_refresh` takes a blocking `with lock` and
  re-reads state inside it, because there is no non-blocking advisory lock
  (G2-6). Two refreshes of one dataset, started at once, must produce one
  refresh and one no-op — not two writes, and never a torn dataset.
- **The publish swap against a live reader.** A viewer rendering a dashboard
  while `publish` repoints `current` must see one whole version or the other.
  Design §7 says the rename makes that true; nothing has tried it.
- **The secret, and any other first-use file.** G6-3's fix, verified under
  concurrent first requests.

### 2.5 Assertions that cannot pass for the wrong reason

The end-to-end suite keeps `curl` — it is the right tool for "is the wiring
real" — but stops asserting on substrings that a stylesheet can satisfy.
Assertions move to markers that exist only when the thing under test rendered:
an element id, a data attribute, a response header, a status code. Where a
body substring is genuinely the assertion, it is scoped to the fragment rather
than matched against the whole page.

This is a mechanical pass over 133 assertions, and its measure is not that the
suite still passes. It is that **each assertion is checked for whether it could
pass with the feature removed** — which is the only way to catch the silent
direction.

### 2.6 The adversarial pass on the front doors

Two surfaces take input from outside and neither has been pushed on:

- **The record validator** — the front door for author-supplied JSON. Deeply
  nested layouts, cyclic-looking structures, absurd counts, wrong types in
  every slot, unicode and empty names. It must refuse, not raise, and never
  hang.
- **`gdash_sql`** — param binding and identifier handling. LDAP escaping got
  RFC-level attention in GDASH-5 because a directory made the risk vivid; SQL
  never got the same treatment, and it is the older surface.

## 3. Construction rules

Unchanged from previous phases, and additionally:

- **No new capability.** If something in this phase adds a feature, it is out
  of scope and belongs in a brief that says so. Fixing a defect the tests
  uncover is in scope; extending behaviour while nearby is not.
- **Every new test must be able to fail.** A test is written, then the code it
  covers is deliberately broken to watch it go red, then the code is restored.
  An assertion never observed failing is an assertion nobody has verified.
- **Coverage is reported as what is *not* covered.** The DONE note names the
  modules and branches still dark, by name, rather than claiming a percentage.

## 4. Tests

The phase is tests, so the list above is the deliverable. Two rules govern the
shape:

- **Hermetic first.** Anything that can be proved without a socket, a
  container or a database is proved that way, and the opt-in runners keep only
  what genuinely needs a live service. That split is what G5-7 established and
  §2.3 is the biggest outstanding violation of it.
- **The suite must still be fast enough to run constantly.** If concurrency
  tests make it slow, they get their own runner rather than being dropped —
  but the default suite stays the thing that runs on every change.

## 5. Done means

1. Multi-worker is a tested configuration, not an untried one, and the
   readiness line is right in both `serve` shapes.
2. `gdash_app`'s authorization is a table-driven hermetic test, including the
   404-vs-403 disclosure rule.
3. The LDAP provider's policy runs in the default suite against a scripted
   directory, and the live runner still passes unchanged.
4. The refresh lock and the publish swap have tests that produce the race
   rather than describing it.
5. `secret_of` writes atomically, like every other durable write in gdash.
6. Every end-to-end assertion has been checked against the question "could
   this pass with the feature removed?", and the ones that could no longer can.
7. The validator and `gdash_sql` have an adversarial pass, and refuse rather
   than raise.
8. All three runners pass; findings recorded; the DONE note names what is
   still uncovered.

## 6. Deliberately not built

Any new capability at all, by construction. Performance work: this phase may
*measure* and record numbers, but tuning is a different activity with a
different risk profile and does not belong in a phase whose job is confidence.
Property-based or generative testing frameworks — gBASIC has none and writing
one is a project. FHS-mode verification and the systemd unit: those are
GDASH-8's step-0 and belong with the deployment work, not before it. Rate
limiting and lockout, still GDASH-8. Anything the tests uncover that is a
missing feature rather than a defect gets a finding, not a fix.

---

## 7. DONE note

All eight §5 criteria met. **25 suites — 744 in-process assertions, 22
multi-worker, 9 concurrency, 144 end-to-end** — green from a clean checkout
with no services running, ending scratch-clean and process-clean; the opt-in
live-Postgres runner passes 8/8 and the live-LDAP runner 49 plus 16 over HTTP.

**Built:** multi-worker as a tested configuration, with readiness correct in
both `serve` shapes; `gdash_app` in process, its authorization rule as an
18-cell table; a seam under the LDAP wire and 56 hermetic assertions against a
scripted directory; the refresh lock and the publish swap tested by producing
the races; `secret_of` serialized and atomic; an assertion audit that renders
the page furniture and refuses any end-to-end needle found in it; and
adversarial passes over both input surfaces.

**What the phase actually found**, which is the measure of whether it was worth
inserting:

- **gdash could not be installed or relocated at all** (G6-8) — a path literal
  into the sibling gbasic checkout, invisible for five phases because every
  process starts from the repo root. That is GDASH-8's whole phase, blocked by
  a string, and the fix was one word.
- **The record validator raised instead of answering** on nine kinds of
  author JSON (G6-15), in code that runs inside request handlers, where a
  raise kills the worker.
- **Eight end-to-end assertions were passing for the wrong reason** (G6-6),
  found mechanically rather than by reading.
- **A hollow assertion survived mutation testing** (G6-12) — the one the whole
  G5-4 ruling rests on. It asserted the absence of data, not the discipline of
  the strategy.
- **`secret_of` was the only non-atomic durable write in gdash** (G6-3), and
  the race reproduced one attempt in five against the pre-fix code.
- **A library could define a function twice, silently** (G6-11) — escalated
  and now a platform error.
- **The suite left a process behind on every run** (G6-9), because
  scratch-clean checked directories and nothing checked processes.

**Deliberately not built** — §6 stands, with these to record:

- **Ten modules still have no dedicated test**, and they are named rather than
  counted: `gdash_auth_ldap` (765 lines — its policy is covered by
  `test_directory`, its wire only by the live runner), `gdash_cli` (475 —
  covered end-to-end only), `gdash_session_files` (123), `gdash_server` (111),
  `gdash_authcfg` (85), `gdash_refresh_child` (67), `gdash_scheduler` (60),
  `gdash_source_fixture` (52), `gdash_source_pg` (51), `gdash_audit` (38).
  Most are exercised indirectly; none is exercised deliberately.
- **The SSE stream ceiling is unresolved** (G6-10). Concurrent streams do not
  establish reliably, it does not scale with worker count, and I could not
  separate worker pinning from curl's buffering with a shell. GDASH-8 owns the
  number, and the plan already asks for it.
- **The worker count cannot be configured** (G6-7) — `workers` must be a
  number literal. GDASH-8's decision: a literal a packager patches, or
  `webserver.listen` at the cost of the block's static checking.
- **No performance work.** This phase measured where it had to and tuned
  nothing; the O(n²) `mid` scans and the ~80µs-per-value money formatting are
  still unmeasured at scale.
- **No property-based testing.** gBASIC has no framework and writing one is a
  project. Mutation testing was done by hand, five mutations at a time, and
  found the thing the suite could not.
- **A dataset named for a SQL keyword is still accepted** (G6-17), by
  decision.

**Design edits owed** (the maintainer's), unchanged from GDASH-5 except that
§5's shared-nothing claim can now be stated as observed rather than intended.

**Cross-repo:** `gdash6_platform_report_duplicate_defs.md` is **closed** —
fixed at gbasic `f21486e`. The G5-9 string report is closed. G6-16 (a NUL
truncating a record key) is the one corner still open, and it is small.
