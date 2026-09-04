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
