# GDASH-5 — Findings

**Status:** step-0 complete, and it fails.
**Platform:** gBASIC `5c2ce75`. Everything here was probed or read in the
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
