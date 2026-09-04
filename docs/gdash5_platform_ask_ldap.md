# Cross-repo ask — an LDAP client module

**Raised by:** gdash, at GDASH-5's step-0, where it is a blocker.
**Ruled by:** the gbasic repo, through its own process.
**Status:** **ANSWERED 2026-09-02**, gbasic `d2dc8fb`. The `ldap` module is
built: `ldap.connect` / `bind` / `search` / `close`, over libldap, guarded by
`HAVE_LDAP`. Ruling and rationale in gbasic `docs/ldap_design.md`; reference
entry in `docs/reference.md`; suite `tests/run_ldap.sh`.

Four things to read before using it.

1. **`bind` returns a value, it does not raise.** `{ ok, reason, code, message }`
   with `reason` one of `""`, `invalid_credentials`, `unreachable`,
   `tls_failed`, `timeout`, `server_error`. The distinguishability you asked
   for is enforced by shape: a caller has to read `reason` to learn anything.
2. **`security` is required and has no default** — `ldaps`, `starttls` or
   `plain`. A cleartext bind must be a word somebody typed.
3. **An empty password is refused, not sent.** LDAP would treat it as an
   unauthenticated bind and the directory would answer *success*.
4. **The gBASIC layer above is not provided, deliberately** (design §7). DN
   construction, `memberOf` walking and group-name normalisation are policy,
   and shaping them from this side would be the failure your own ask names.
   That layer is yours.

**And the limit, stated plainly: it has never met Active Directory or
OpenLDAP.** No such server is reachable from the gbasic host, so it is tested
against a mock that speaks real BER over a real socket. The first thing to do
is point it at a real directory, and the first thing to expect is that
something is wrong.

---

## Why gdash cannot do this itself

`docs/gdash_design.md` §8 names three identity tiers. Tier 2 is "LDAP(S) bind
against AD — covers most directory-using organizations; yields `memberOf`
groups", and it is the tier that matters commercially: gdash is an intranet
product, and an intranet has a directory.

Step-0 found no way to reach one (G5-1): no `ldap` module, no raw TCP client
to speak the protocol over, and no `ldapsearch` to shell out to. LDAP is
ASN.1 BER over TCP with TLS underneath — a client is a real project, and an
authentication client that is subtly wrong is a hole rather than a bug.

## What gdash actually needs

Deliberately small, and stopping well short of "support LDAP":

- **Bind.** Simple bind with a DN and a password, over LDAPS or StartTLS, to a
  named host and port. Success or failure — that is the authentication.
- **Search.** One search: base DN, scope, filter, and a list of attributes to
  return. gdash needs it twice — once to turn a username into a DN, once to
  read `memberOf` (or, for the directories that do it the other way, to find
  groups whose `member` is the user's DN).
- **Certificate verification on by default**, with an explicit opt-out that is
  named in configuration rather than implied by silence. An intranet CA is the
  normal case, so a way to name a CA bundle matters more here than it would
  for a public service.
- **Failure that can be told apart.** "Wrong password" and "the directory is
  unreachable" must be distinguishable: the first is shown to the user, the
  second is an operator's problem and must not be reported to a viewer as a
  bad password.

Not asked for: modify, add, delete, referral chasing, SASL/GSSAPI, connection
pooling, paged results, or a schema layer. gdash reads two things and binds.

## The shape, following `smtp`

`smtp` is the precedent (G5-2): a native transport with a small typed surface
(`smtp.send(config, message)`, `config` carrying `host`/`port`/`security`),
and a pure-gBASIC composer above it that never touches the wire.

An `ldap` module would divide the same way — native bind and search, with DN
construction, `memberOf` walking and group-name normalisation written in
gBASIC above it, where gdash can read and test them. That division is what
makes this bounded.

## Timing, and what gdash does meanwhile

Not urgent in the sense that gdash is stalled: GDASH-5 narrows to the provider
interface, preview-as and auth-provider connection profiles, none of which
depend on the answer. What it does mean is that gdash's **second** identity
tier does not exist, and design §8 is written as though it will.

The risk of building the interface with only one implementation behind it is
real and named: a seam shaped by local accounts alone will fit local accounts.
GDASH-4's session seam had the same risk and the platform's ruling was to
build from one real implementation anyway. The difference here is that the
second implementation is blocked on someone else, so the interface is being
shaped by *reading* LDAP's requirements rather than by meeting them — which is
exactly the "designed from two hypotheticals" failure that ruling warned about,
inverted. If the module lands, the first thing gdash should expect is that the
interface is wrong somewhere.

---

## Prompt to send to the gBASIC session

> gdash has reached GDASH-5 (directory auth and personalization) and step-0
> fails on its central deliverable. gdash's design §8 names LDAP(S) bind
> against AD as identity tier 2 — the tier that matters for an intranet
> product, since an intranet has a directory.
>
> There is no way to reach one. Checked, against `5c2ce75`: no `ldap` in
> `docs/reference.md`, none in `stdlib/`, not named in any design document; no
> raw TCP client to speak the protocol over (the platform has an HTTP server
> and client, `pg`, `sqlite`, `odbc` and `smtp`, each a purpose-built module);
> and no `ldapsearch` on the host to shell out to. So it cannot be reached
> natively, cannot be hand-rolled in gBASIC, and has no fallback here.
>
> I am not proposing to hand-roll it even if a socket appeared. LDAP is ASN.1
> BER over TCP with TLS underneath; a client is a real project, and an
> authentication client that is subtly wrong is a hole rather than a bug.
>
> What gdash needs is deliberately small:
>
> - **Bind** — simple bind, DN plus password, over LDAPS or StartTLS to a
>   named host and port. Success or failure is the authentication.
> - **Search** — one call taking base DN, scope, filter and attribute list.
>   gdash uses it exactly twice: username → DN, and reading `memberOf` (or
>   finding groups whose `member` is the user's DN, for directories that model
>   it that way).
> - **Certificate verification on by default**, with an opt-out named in
>   configuration rather than implied by silence, and a way to name a CA
>   bundle — intranet CAs are the normal case here.
> - **Distinguishable failure.** "Wrong password" and "the directory is
>   unreachable" must not be the same error. The first is shown to the user;
>   the second is an operator's problem and must never reach a viewer as a bad
>   password.
>
> Not asked for: modify/add/delete, referrals, SASL/GSSAPI, pooling, paged
> results, or a schema layer. gdash binds and reads two things.
>
> On shape, `smtp` looks like the right precedent: a native transport with a
> small typed surface (`smtp.send(config, message)` carrying
> `host`/`port`/`security`), and a pure-gBASIC composer above it that never
> touches the wire. An `ldap` module would divide the same way — native bind
> and search, with DN construction, `memberOf` walking and group-name
> normalisation written in gBASIC above it where gdash can read and test them.
> That division is what makes this bounded rather than "support LDAP".
>
> gdash is not stalled: GDASH-5 narrows to the provider interface (with
> GDASH-4's local accounts as its first implementation), preview-as, and
> auth-provider connection profiles. None of those depend on the answer.
>
> One thing worth saying plainly, because it is the opposite of the ruling you
> gave on the session seam. There you said to build from one real
> implementation rather than design from two hypotheticals, and you were right.
> Here the second implementation is blocked on you, so I am shaping a seam by
> *reading* LDAP's requirements instead of meeting them — which is the failure
> that ruling warned about, inverted. If the module lands, the first thing to
> expect is that gdash's provider interface is wrong somewhere, and that is a
> cost of the sequencing rather than a surprise.
