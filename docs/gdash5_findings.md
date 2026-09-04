# GDASH-5 — Findings

**Status:** the phase is complete. Step-0 failed, was escalated, and now passes.
G5-1 and G5-2 are kept as written — a finding that was true when it was made
is not edited later to look better.
**Platform:** gBASIC `5c2ce75` at step-0; `bcd0258` for everything from G5-8
on. Everything here was probed against a running system or read in the
platform's own source, not inferred from its design docs.

---

## G5-1 — there is no LDAP client, and one cannot be written in gBASIC

**Step-0, and the phase's central deliverable depends on it.** The plan's
GDASH-5 paragraph opens with "LDAP(S) bind provider behind the provider
interface, group resolution via `memberOf`". Neither is reachable.

What was checked:

- **No `ldap` anywhere.** Not in `docs/reference.md`, not in `stdlib/`, not
  named in any gbasic design document.
- **No raw TCP client.** The platform has an HTTP *server* (`server` block,
  `webserver`), an HTTP client, `pg`, `sqlite`, `odbc` and `smtp` — every one
  of them a purpose-built module. There is no general socket a protocol could
  be spoken over.
- **No shell-out fallback on this machine.** No `ldapsearch`, no `ldapwhoami`.

So LDAP cannot be reached natively, cannot be hand-rolled in gBASIC, and
cannot be shelled out to here. This is not a case like GDASH-2's missing timer,
where the premise failed and the phase changed shape around a mechanism that
did exist: there is no mechanism.

**And hand-rolling it would be wrong even if there were a socket.** LDAP is
ASN.1 BER over TCP with TLS underneath. A client is a substantial project, and
an authentication client that is subtly wrong is not a bug — it is a hole. The
one thing worse than no directory support is directory support that appears to
work.

**Ruling: the phase narrows and the platform is asked.** The provider
*interface* is built now with the local accounts of GDASH-4 as its first
implementation, and the rest of the phase's scope — preview-as, auth-provider
connection profiles — does not depend on LDAP at all. That is not designing
around the missing premise; it is the part of the phase the premise never
touched, and the plan itself sequences it that way ("behind the provider
interface").

This mirrors what the platform endorsed for the session seam in GDASH-4: build
from one real implementation, extract when the second arrives. The difference
is that here the second implementation is blocked on someone else, so the
interface must be shaped by reading LDAP's requirements rather than by meeting
them.

## G5-2 — `smtp` is the precedent an `ldap` module would follow

Worth recording because it makes the ask concrete rather than open-ended.

`smtp` is a **native** module (13 sites in `src/eval.c`) with a small typed
surface — `smtp.send(config, message)`, where `config` carries
`host`/`port`/`security: "starttls"` — and a **pure-gBASIC composer**
(`stdlib/mail.bas`) layered above it that frames messages and never touches
the wire. The transport is native because it must be; everything that could be
gBASIC is gBASIC.

An `ldap` module would take the same shape: a native bind-and-search surface,
with anything gdash needs above it (DN construction, `memberOf` walking, group
name normalisation) written in gBASIC where it can be read and tested. That
division is what makes the ask a bounded piece of work rather than "support
LDAP".

---

## G5-3 — the module landed, and it works against a real directory

`ldap` arrived at gbasic `d2dc8fb`, native over libldap, with exactly the
surface asked for: `connect` / `bind` / `search` / `close`, `security`
required with no default, referral chasing disabled and not configurable, and
`bind` returning `{ ok, reason, code, message }` rather than raising.

The platform's own note said it had never met AD or OpenLDAP and asked gdash to
point it at a real one. **It now has been.** `podman` is installed and rootless
here, so a real **OpenLDAP 2.6.10** runs in a container on loopback, seeded
with two users and three `groupOfNames` groups. Every path below is against
that, not a mock.

| case | result |
|---|---|
| correct bind | `ok=true`, `reason=""`, `code=0` |
| wrong password | `ok=false`, `reason="invalid_credentials"`, `code=49` |
| DN that does not exist | `ok=false`, `reason="invalid_credentials"` — no enumeration oracle |
| empty password | refused locally, `reason="invalid_credentials"` |
| server not listening | `ok=false`, `reason="unreachable"` |
| StartTLS to a plaintext server | **raises at `connect`** — no downgrade |
| LDAPS to a plaintext port | `ok=false`, `reason="unreachable"` |
| `security: "none"` | refused at `connect` |
| `security` omitted | refused at `connect` |
| search by `uid` | one hit, correct DN, requested attributes only |
| search matching nothing | empty array, not an error |
| every attribute value | an array, including single-valued `cn` |

The distinguishability requirement holds against a real server: a wrong
password and an unreachable directory are different answers, and no
configuration produces a silent cleartext bind.

## G5-4 — `memberOf` is empty on stock OpenLDAP, and that breaks the design's assumption

**The finding the platform asked for, and it is not in the module.** It is in
what design §8 and gdash's own ask both assumed.

Design §8 says LDAP "yields `memberOf` groups". Against real OpenLDAP:

```
search (uid=ada), attributes: ["memberOf"]   ->  attrs = {}
search ou=groups, (member=uid=ada,...)       ->  cn=analysts, cn=finance
```

`memberOf` is produced by the **`memberof` overlay**, which OpenLDAP does not
enable by default. Active Directory populates `memberOf` natively; OpenLDAP
does not unless an operator turned it on. So a provider that reads only
`memberOf` gets **zero groups** from a stock OpenLDAP — and zero groups is a
*legitimate answer*, not an error, so it fails **silently**. Every dashboard
gated on a group would refuse everyone, and the log would show successful
logins.

**Ruling: the group strategy is named in configuration, with no default.** A
profile says either `memberof` (read the attribute) or `search` (find groups
whose `member` is the user's DN, given a base and a filter). Not auto-detected
and not fallen back to, for the same reason the platform gave for requiring
`security`: guessing wrong here produces a plausible answer rather than a
failure, so it has to be a word somebody typed and can be found in a
configuration review.

This is the cost the ask predicted — "if the module lands, the first thing to
expect is that gdash's provider interface is wrong somewhere". It was wrong
here, and it was wrong before the interface existed, in the design sentence
the interface would have been built from.

## G5-5 — TLS failure raises from `connect`; bind's `tls_failed` is not what a caller meets

`bind` returning a value rather than raising is the module's load-bearing
property, and the documentation is emphatic about it. That emphasis leads a
caller to guard `bind`. But a TLS failure happens at **connect**, and connect
**raises**:

```
starttls to a plaintext server -> connect RAISED: ldap.connect: StartTLS failed ...
```

A caller who guards only `bind` — the shape the docs steer toward — takes the
raise. In gdash that is not a stack trace in a terminal: a raise inside a
request handler kills the worker (PLAT-WEB, let-it-crash). An intranet
directory with an expired certificate would therefore crash a worker on every
login attempt instead of showing "sign-in is unavailable".

gdash guards `connect` as well, so it is not exposed. Reported because the
next caller will read the same documentation and reach the same wrong
conclusion, and because it leaves `tls_failed` — a documented `bind` reason —
apparently unreachable on this path.

## G5-6 — never ask a directory for every attribute

A search with no `attributes` list returns everything the bind identity may
read. Bound as the directory admin, that included `userPassword`:

```
keys = objectClass,uid,cn,sn,mail,userPassword
```

Correct LDAP behaviour, correct module behaviour, and a rule for gdash: the
provider names the attributes it wants, always, and no attribute record is
ever logged, audited or put in a record. A service account should also be
scoped to read only what it needs — which is a deployment instruction, not
something gdash can enforce.

## G5-7 — a real directory is now part of gdash's test tooling

`scripts/ldap_test_directory.sh` builds and runs the OpenLDAP container. The
live LDAP runner is opt-in and gated on `GDASH_LDAP_TEST=1`, like the Postgres
one; the hermetic suite tests the **policy** layer — DN construction, group
strategy, attribute normalisation — which needs no directory at all, the same
split the scheduler uses between a pure due-decision and the process that acts
on it.

## G5-8 — all three fixed, and one of them was mine

Verified against the real directory at gbasic `bcd0258`:

- **`empty_password` is a distinct reason**, so a caller can tell its own bug
  from the directory's answer. In the reference's reason list.
- **TLS failure now arrives as `bind` returning `tls_failed`** instead of
  raising from `connect`. StartTLS against a plaintext server:
  `ok=false reason='tls_failed'`, no raise. The documented reason is reachable
  and the documented shape is the true one, so a caller who guards `bind` — the
  shape the docs steer toward — is now actually safe.
- **`docs/ldap_design.md` §7 states the `memberOf` assumption**: AD's shape,
  OpenLDAP needs the overlay. §8 records that AD itself is still untested.

`security: "none"` and omitted `security` still raise at `connect`, which is
right and is a different thing: those are programming errors found at
configuration time, not runtime conditions a caller has to branch on.

**One of the three findings was mine.** The first re-run after the fix showed
every bind answering `unreachable`, which looked like a regression in the
module. It was not: my `ldap_test_directory.sh up` waited for an **open TCP
port**, and podman publishes the port before slapd is serving on it. A
directory that is listening but not yet answering looks exactly like a broken
client.

The readiness check is now a real bind (`ldapwhoami` inside the container), not
a socket connect. Recorded because it is the same mistake in a different
costume: "the port is open" and "the service works" are two facts, and I had
written code that treated them as one — which is what G4-10 was about, and
what G5-4 was about, in a third place.

## G5-9 — `replace` truncates its haystack at the first NUL, silently

**Found while writing the LDAP escapes, which is the worst possible place for
it.** RFC 4515 requires NUL to be escaped in a search filter; RFC 4514 requires
it in a DN. The obvious implementation is a chain of `replace` calls. It is
wrong in two different ways:

```
replace(s, chr(0), "\00")        -> raises: "replace: search string cannot be empty"
split(s, chr(0))                 -> raises: "split separator cannot be empty"
len("a" + chr(0) + "b")          -> 3
len(replace("a" + chr(0) + "b", "a", "A"))   -> 1
len(trim("a" + chr(0) + "b"))    -> 1
```

The first two are an inconvenience: a `chr(0)` needle is treated as the empty
string and refused. **The third is data loss with no error.** `replace` is
given a three-character string and returns a one-character one, because it
reads its haystack as a C string and stops at the NUL. `trim` does the same.
`len`, `mid`, `code` and `upper` are all binary-safe, so the failure is not
uniform and cannot be reasoned about from one probe.

A sweep of the whole family found five affected builtins, and the line they
fall on is not one a caller could guess: `replace`, `trim`, `join`, `split`
and **`ends_with`** are C-string-based, while `len`, `mid`, `upper`, `lower`,
`reverse`, `+`, `contains`, `starts_with`, `hex_encode`, `encode`, `string`
and `code` are length-aware. `contains` and `ends_with` are in the same family
and disagree — and `ends_with` does not shorten a value, it returns the wrong
boolean.

gBASIC strings carry an explicit length and the reference is emphatic — "a
binary-safe sequence of bytes … strings are not NUL-terminated from the
program's point of view" — so this is a defect rather than a documented
limitation. Its shape is the dangerous one: the naive code produces
a *shorter, plausible* value rather than an error, and the character it eats is
the one that most needs escaping.

Both LDAP escapes are therefore single hand-written scans over `mid`/`code`,
which are binary-safe, and both are asserted to survive a NUL. That is the
right implementation anyway — one pass means an escape introduced by one rule
is never re-escaped by the next — but it is here because of this, not because
of that.

One place in gdash is theoretically exposed and is not being changed:
`gdash_diff` splits snapshot text on newlines, so a dashboard record containing
a literal NUL inside a JSON string would diff wrongly. It is left alone because
the fix belongs in `split`, the input is a file an author wrote, and a
hand-rolled line splitter would be a worse thing to own than a known
limitation. Recorded rather than quietly tolerated.

Written up for the platform in `gdash5_platform_report_string_nul.md`.

## G5-10 — the namespace audit caught the first new module, again

`gdash_auth.check` collided with `gdash_record.check` on the audit's first run
after the module was written. That is the fourth phase in a row the audit has
caught something on the first run of new code, and the second time the offender
was a name as ordinary as `check`.

Nothing dramatic happened — the platform's resolution fix (gbasic `d08409f`)
means a library's own internal calls are safe now — but a caller writing a bare
`check` outside both libraries would still get whichever loaded last. Renamed
to `check_config`. Recorded only to note that the audit keeps paying for
itself in a codebase where every module is named for a noun.

## G5-11 — putting a chain in front of a security property nearly broke it

GDASH-4 closed a user-enumeration oracle: an unknown username spends a hash
anyway, so it does not answer faster than a wrong password.

The provider interface needs a different fact from the same function — *does
this provider have this username* — and the obvious implementation answers it
first:

```
if is_unknown(lookup(db, username)) then
    return gdash_auth.miss()          ' <- returns in microseconds
end if
```

That is correct as a chain, and it reopens the oracle: with local as the only
provider, an unknown username now returns without hashing. The property was
not deleted; it was **routed around**, by a function that was added for an
unrelated reason and never touched the code that held it.

The local provider spends a hash and then reports `miss`. Recorded because the
general shape is worth naming: a seam introduced in front of existing code
inherits none of that code's guarantees automatically, and the guarantees most
likely to be lost are the ones enforced by *timing* or by *doing extra work*,
because those look like waste to anyone reading the new path in isolation.

## G5-12 — bounded-stale identity, and the write it must not cause

A directory cannot be asked on every request the way `users.json` can, so the
resolved identity is materialized into the session and re-resolved every
`revalidate` seconds. Two things fell out of that which were not obvious:

- **The cache write must be conditional.** Writing the session record after
  every revalidation is correct for a directory (one write per interval) and
  wrong for local accounts, where `revalidate: 0` means every request — turning
  reading a dashboard into a write. It is skipped when `revalidate` is 0,
  which is the same reasoning `gdash_session.active` already applies to its
  `touch_after` slack.
- **A directory outage must not log everyone out.** The revalidation path
  distinguishes *the user is gone* (destroy the session) from *the directory
  would not say* (keep it, audit it, let the absolute and idle limits bound
  it). This is design §3's stale-but-coherent rule applied to identity rather
  than to data, and the argument is the same: bounded staleness beats a hard
  failure, and the bound is configuration rather than accident.

The audit line is emitted only when a revalidation was actually due, which is
at most once per interval per session — otherwise a directory outage would
produce a log flood on top of an outage.
