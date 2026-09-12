# GDASH-11 — Findings

**Status:** complete. One open dashboard used to make gdash answer nothing
else; it no longer does. Suite green at 29 suites, 911 in-process assertions,
21 multi-worker, 11 ceiling, 9 concurrency, 186 end-to-end (10 of which
execute the page's JavaScript under node).

---

## G11-1 — the ceiling was not a ceiling, it was a bug with a number attached

Recorded twice before this phase, both times as a limit to be aware of:

> G6-10 — the SSE ceiling is exactly the worker count.
> G8-9 — an open dashboard holds a worker; four workers serve three viewers.

Both true, both measured, and both filed as *facts about gdash's shape*. The
operations doc said so plainly and told the operator to buy workers. What
nobody did was ask what the number meant at the value it actually ships with.

Step 0 asked:

```
  workers=1  streams=0   baseline=200  next request=200 after 0.1s
  workers=1  streams=1   baseline=200  next request=000 after 5.0s
  workers=2  streams=1   baseline=200  next request=200 after 0.1s
  workers=2  streams=2   baseline=200  next request=000 after 5.0s
  workers=4  streams=3   baseline=200  next request=200 after 0.1s
  workers=4  streams=4   baseline=200  next request=000 after 5.0s
```

`000` is curl's code for *no response at all*. The shipped default is one
worker, so the shipped default serves **zero** concurrent viewers: open a
dashboard and the same person in a second tab gets nothing.

**The lesson is not about SSE.** It is that "known ceiling, named escape
hatch" reads like a decision and can hide an unasked question. The ceiling was
stated as a formula, and a formula does not evaluate itself. The question that
turned it from documentation into a defect took one script and five minutes:
*what does this number say at the value we ship?*

## G11-2 — a suite that flaked for the same reason, and said so

`run_workers.sh` opened two SSE streams and retried up to four times, with a
comment explaining that opening two streams "fails outright perhaps one
attempt in four even with workers to spare" and calling that a setup flake.

It was not a flake. It was the ceiling, showing through the test meant to
measure past it: two held streams on a four-worker server left two workers for
a suite that was also making requests, and the third stream — the one whose
absence made the count "two, not more" — was the ceiling being hit.

The comment even recorded the right observation ("larger counts were tried and
could not be established reliably") and drew the wrong conclusion from it.
**An intermittent failure that has been explained is more dangerous than one
that has not**, because the explanation stops anyone looking. The retry loop
is gone, and the suite now polls from eight concurrent viewers instead of
holding two streams.

## G11-3 — where the design was load-bearing and where it was incidental

Design §5: *"SSE carries only global events, observed via the filesystem."*

Two claims in one sentence, and only one of them is doing work:

- **Load-bearing** — the truth lives in a file, so any worker can observe it
  without sharing memory with any other. This is what makes the worker pool
  possible at all, and it is untouched.
- **Incidental** — the carrier is SSE. Nothing depends on the connection
  staying open. The handler was *already polling the filesystem*; it was
  simply polling it in the wrong process.

Separating those two took longer than implementing the change. The earlier
report called this a platform limitation and recommended waiting for a
platform capability. That was wrong, and it was wrong in a specific way worth
naming: **a mechanism named in a design document acquires the authority of the
principle it was chosen to serve.** The fix was always gdash's.

## G11-4 — the page's JavaScript had never been run

gdash builds its client shim by string concatenation in gBASIC. Until this
phase nothing parsed the result, let alone executed it: a typo would have
reached every dashboard, broken every slicer, and left the suite green,
because the server was fine and the server is what the suite tested.

That was survivable while the shim only enhanced a page the server had already
rendered. It stopped being survivable the moment the shim became the only
thing carrying the refresh notification.

`tests/shim_check.js` runs it under node in a bare `vm` context — which also
proves the shim depends on nothing but the browser globals the check stubs —
and drives the poll with canned answers. It asserts the four decisions the
client now owns: an unchanged version does nothing, a moved version reloads, a
moved publish pointer reveals the notice **without** reloading (design §7: a
pinned viewer is offered the new version, never yanked onto it), and a failed
poll changes nothing, because reloading on a network blip would throw away
every open tab's slicer selection at once.

Ten assertions, all of which fail when a stray `}` is introduced into the
generated JavaScript. Verified.

## G11-5 — JSON quoting does not close a `<script>` element

The baseline the page carries is embedded at render time, not learned on the
first poll — a refresh landing in the second between render and first poll
would otherwise go unseen until the poll after that. Embedding means putting a
value inside a `<script>` element, and the publish pointer is a filename read
off the filesystem.

`encode()` produces valid JSON, and valid JSON does not escape `<` or `>`. A
pointer containing `</script>` would have ended the element from inside a
string literal, where no amount of correct quoting helps. Both brackets are
now spelled as `<` / `>`.

Not reachable today — pointers are validated leaf names. Recorded because the
reasoning that makes it unreachable lives in a different module from the code
that depends on it, and that is exactly the distance across which an
invariant goes quietly stale.

## G11-6 — a login-throttle assertion that raced, and the shape of the fix

Not GDASH-11's doing; found because a full-suite run failed once in three
while this work was in progress, and a suite this phase depends on has to be
trustworthy.

The end-to-end run asserted five login attempts returned `401 401 401 429 429`
and intermittently saw a fourth-position 429 followed by a `401`. That was
**correct behaviour**: the wait owed after a third failure is one second, and
three HTTP round trips on a loaded machine can take longer than that, at which
point the guesser has genuinely waited and is genuinely entitled to try again.

The exact schedule is already pinned in `test_throttle.bas` against an
injected clock, where it costs no wall time and cannot race. The end-to-end
run was re-testing it badly. It now asserts the two things only it can — that
a 429 reaches the socket, and that **the wait ends**, since a lockout that
never lifts is a denial of service an attacker aims at somebody else's
account by failing on their behalf.

**The rule:** when a timing assertion flakes, ask which suite owns the
property. A slow assertion of a fast rule usually belongs somewhere else
entirely.

## G11-7 — what the poll costs, measured

One worker, sequential, reference dashboard:

| request | cost |
|---|---|
| `GET /d/{name}/version` | 28 ms |
| `GET /d/{name}` (every visual queried) | 57 ms |
| `GET /whoami` | 6 ms |

A viewer with a tab open makes 0.2 requests a second, where before that viewer
occupied a whole process. Measured rather than extrapolated, at the **default
single worker**, with viewers polling while somebody loads a page:

| workers | viewers | polls | failed | worst page load |
|---|---|---|---|---|
| 1 | 10 | 30 | 0 | 87 ms |
| 1 | 30 | 90 | 0 | 71 ms |
| 4 | 30 | 90 | 0 | 71 ms |

Thirty viewers cost one worker nothing measurable. The same configuration
served zero before this phase.

What workers are for turns out to be a burst of *page loads*:

| workers | simultaneous page loads | failed | slowest |
|---|---|---|---|
| 1 | 10 | 0 | 482 ms |
| 1 | 20 | 0 | 951 ms |
| 4 | 10 | 0 | 195 ms |
| 4 | 20 | 0 | 675 ms |

Nothing fails at any of these. The queue is the whole effect, which is what a
worker pool is supposed to do and what it never got to do before.

The poll costs 28 ms rather than `whoami`'s 6 because it loads and validates
the dashboard record to make the same access decision the page makes. That is
deliberate and it is priced: a version number leaking to someone who may not
open the dashboard tells them it exists and that its data moved. Named here so
that if the poll ever becomes the busiest thing a deployment does, the first
place to look is already written down.

## G11-8 — the ceiling suite runs at the default, on purpose

`tests/run_ceiling.sh` unsets `GDASH_WORKERS`. Every other suite that touched
concurrency set it to four, which is why ten phases of green suites never saw
this: at four workers the suites had headroom, and headroom is exactly what a
person running `gdash-server` to try it does not have.

It asserts three different kinds of thing, because any one alone would rot:

1. **What the page instructs the browser to do** — no `EventSource`, no
   `WebSocket`, and a poll on a timer. A server that behaves perfectly still
   has the ceiling back if the page opens a long-lived connection.
2. **That the route which pinned a worker is gone** — not merely unused. An
   endpoint whose only effect is to occupy a worker is one any viewer entitled
   to the dashboard could still point at, four times, deliberately.
3. **That viewers behaving that way are served** — six polling, one worker,
   and a further viewer gets their page. Worst observed wait: 119 ms.

Verified by mutation: holding the worker again produces exactly the original
failure, `000` and a ten-second wait, in the suite written to catch it.

---

## Deliberately not built

- **A configurable poll interval.** One number in one place until there is a
  reason for two.
- **Caching the access decision to make the poll cheaper.** 28 ms is not a
  problem at any load gdash has been asked for, and a cache of authorization
  answers is a thing to get wrong later. G11-7 names where to look first.
- **TLS.** Still blocked on the platform (`gdash8_platform_report_tls.md`).

## Open, and owed

- **Design §5's sentence names SSE as the carrier.** It is now wrong in its
  mechanism and right in its principle. The correction is the maintainer's;
  this phase did not touch the design document.
- **A platform ask, not a blocker:** a stream handler that can wait without
  holding its worker would beat polling — lower latency, no idle requests.
  Filed as `gdash11_platform_ask_stream.md` for the gbasic repo's own process.
  GDASH-11 deliberately did not wait for it, and should not have.
- **The systemd units have still never been started**, only
  `systemd-analyze verify`'d (G8-7, still open).
