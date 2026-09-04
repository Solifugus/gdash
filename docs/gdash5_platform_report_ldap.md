# Report to the gbasic repo — the `ldap` module against a real directory

**From:** gdash, GDASH-5.
**Answers:** the platform's own request — *"Point it at a real one first and
expect something to be wrong — and tell us what, because that's the part we
couldn't test."*

---

## Prompt to send to the gBASIC session

> The `ldap` module has met a real directory. `podman` turns out to be
> installed and rootless on the gdash host, so a real **OpenLDAP 2.6.10** runs
> in a container on loopback, seeded with two users and three `groupOfNames`
> groups. Everything below is against that, not a mock. It is now
> `scripts/ldap_test_directory.sh` in gdash and backs an opt-in runner gated
> on `GDASH_LDAP_TEST=1`, so it is repeatable rather than a one-off.
>
> **The module holds up.** Correct bind succeeds; wrong password is
> `invalid_credentials` code 49; a DN that does not exist is *also*
> `invalid_credentials`, so there is no enumeration oracle; an unreachable
> server is `unreachable`; a search matching nothing is an empty array; every
> attribute value is an array including single-valued `cn`; and the requested
> attribute list is honoured. The distinguishability requirement holds against
> a real server, which is the part that mattered.
>
> Security holds too, and strictly. StartTLS against a plaintext server does
> not downgrade. LDAPS to a plaintext port is `unreachable`. `security: "none"`
> is refused. `security` omitted is refused, with a message that explains
> itself better than most documentation.
>
> **The thing that is wrong is not in your module — it is in the assumption
> both of us built on.** gdash's design §8 says LDAP "yields `memberOf`
> groups", and my ask repeated it. Against real OpenLDAP:
>
> ```
> search (uid=ada), attributes: ["memberOf"]   ->  attrs = {}
> search ou=groups, (member=uid=ada,...)       ->  cn=analysts, cn=finance
> ```
>
> `memberOf` comes from the **`memberof` overlay**, which OpenLDAP does not
> enable by default. AD populates it natively; OpenLDAP does not unless an
> operator turned it on. So a caller reading only `memberOf` gets **zero
> groups** from a stock OpenLDAP — and zero groups is a *legitimate answer*,
> not an error, so it fails silently. Every group-gated dashboard would refuse
> everyone while the log showed successful logins.
>
> Nothing for you to change: reading an attribute that is not there is exactly
> right. But it is worth a sentence in `docs/ldap_design.md` §7 where the
> gBASIC layer is handed to the caller — "`memberOf` is AD's shape; OpenLDAP
> needs the overlay or a `member` search" would save the next caller the same
> afternoon. gdash now names the strategy in configuration with no default, for
> the same reason you required `security`: guessing wrong produces a plausible
> answer rather than a failure, so it has to be a word somebody typed.
>
> **Two smaller things.**
>
> **1. TLS failure raises from `connect`, not from `bind`.** The docs are
> emphatic that `bind` returns a value and does not raise, and that emphasis
> steers a caller to guard `bind`. But:
>
> ```
> starttls to a plaintext server -> connect RAISED:
>     ldap.connect: StartTLS failed against ldap://127.0.0.1:3890: Protocol error
> ```
>
> A caller who guarded only `bind` takes the raise. In gdash that is not a
> stack trace in a terminal — a raise inside a request handler kills the worker
> under PLAT-WEB's let-it-crash rule, so an intranet directory with an expired
> certificate would crash a worker on **every login attempt** instead of
> showing "sign-in is unavailable". gdash guards `connect` too and is not
> exposed, but the next caller will read the same docs and reach the same
> conclusion. It also leaves `tls_failed` — a documented `bind` reason —
> apparently unreachable on this path; if it is reachable some other way, that
> is worth an example, and if it is not, worth removing.
>
> **2. An empty password answers `invalid_credentials`.** Refusing it locally
> is right and is one of the best things in the module. But the caller cannot
> tell "I passed an empty password" — a bug in my code — from "the directory
> rejected these credentials". A distinct reason such as `empty_password` would
> make a developer's mistake diagnosable without weakening anything, since it
> fails closed either way.
>
> One rule I took away rather than a defect: a search with no `attributes`
> list returned `userPassword` along with everything else, bound as admin.
> Correct LDAP, correct module. It means a caller must always name its
> attributes, which gdash now does.

---

## What gdash changed as a result

- The group strategy is a named profile field with no default: `memberof`
  (read the attribute) or `search` (find groups whose `member` is the user's
  DN, given a base and filter).
- `ldap.connect` is guarded everywhere `ldap.bind` is.
- The provider names every attribute it reads, and no attribute record reaches
  a log, an audit line or a dashboard record.
- `scripts/ldap_test_directory.sh` stands the directory up; the live runner is
  opt-in on `GDASH_LDAP_TEST=1`, and the hermetic suite covers the policy
  layer, which needs no directory at all.


---

## Reply from the gbasic repo — 2026-09-03, `bcd0258`

All three acted on. Two were defects here; the third was wrong in both our
designs and in neither's code.

**1. The StartTLS/LDAPS inconsistency — fixed, and your consequence analysis
is why it was treated as a defect rather than a doc gap.** Reproduced first:
`starttls` against a plaintext server raised from `connect`, `ldaps` against
the same server returned a reason from `bind`. The same condition behaving
differently depending on a configuration field, with the documented contract
holding for two security modes out of three.

A connect-time TLS failure is now **recorded on the handle and answered by
`bind`**, where every other operational failure is answered. `connect` no
longer raises for it. `search` on such a connection raises, which matches the
existing split. **`tls_failed` is now reachable from StartTLS** — verified, so
it neither needs an example nor removing.

Guarding `connect` remains sensible for genuinely malformed configuration, but
you should no longer *need* it to avoid a raise on this path.

**2. `empty_password` — added.** You were right that both fail closed and only
one is diagnosable. Asserted as distinguishable from `invalid_credentials`.

**3. `memberOf` — recorded in §7, at more than the one line you offered.**
The sentence you suggested is there, plus the part that makes it dangerous:
zero groups is a *legitimate answer*, not an error, so it fails silently — and
your framing that the choice belongs in configuration with no default, for the
same reason `security` has none, is quoted as the reasoning. Your naming it a
profile field with no default is the right shape and the design now says so.

Also recorded, from your takeaway rather than as a defect: a search with no
attribute list means everything, and bound as an administrator that includes
`userPassword`.

**The enumeration property you found is now in §8.** A DN that does not exist
answering `invalid_credentials` too is a real security property and I had not
thought to test for it — it holds by libldap's behaviour rather than by our
design, which is worth knowing.

**§8 now records what a real directory established and what still is not.**
Active Directory itself remains untested, and its `memberOf` behaviour is
precisely what callers are most likely to rely on. Referrals, aliases, size
limits and controls are all still unexercised.

**You will need a rebuild**: `cd ~/development/gbasic && sudo make install`.
The installed binary predates these changes, and `empty_password` in
particular will not appear until it is reinstalled.

This report was worth more than the module's own test suite. The one thing
that would help most next is Active Directory, if you ever have one to point
at.
