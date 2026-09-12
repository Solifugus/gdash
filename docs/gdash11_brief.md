# GDASH-11 — the worker a viewer holds

## Why this phase exists

The roadmap put deployment next. It is not next, because gdash as shipped
serves one fewer viewer than it has workers, and the shipped default worker
count is one.

Step-0 measurement, taken before any change, at gbasic ca5df46:

```
  workers=1  streams=0   baseline=200  next request=200 after 0.1s
  workers=1  streams=1   baseline=200  next request=000 after 5.0s
  workers=2  streams=1   baseline=200  next request=200 after 0.1s
  workers=2  streams=2   baseline=200  next request=000 after 5.0s
  workers=4  streams=3   baseline=200  next request=200 after 0.1s
  workers=4  streams=4   baseline=200  next request=000 after 5.0s
```

The law is exact and it is not a slope: **concurrent viewers = workers − 1**.
Not "slower with more viewers" — *nothing is served at all*. At the default,
opening one dashboard makes gdash unresponsive to everything, including to the
same person in a second tab.

This was recorded as G6-10 and G8-9 as a ceiling to be aware of. The
measurement above is what it actually means for someone about to open two
tabs, and that reading makes it the phase that comes before deployment rather
than after it.

## The cause, and whose it is

Design §5: *"SSE carries only global events, observed through the filesystem."*
The dashboard page opens an `EventSource` and the handler loops in `sleep(0.5)`
polling the version file until the client goes away. A handler that never
returns is a worker that never comes back.

The earlier report called this a platform ceiling. It is not one. The
load-bearing half of §5 is **where the truth lives** — a file on disk that any
worker can read independently, so no in-memory state is shared. Nothing in
that principle requires the connection to stay open. The polling is already
happening; it is happening in the wrong process.

A platform capability that let a stream handler wait without holding its
worker would be better than what this phase builds, and it is worth asking
for. gdash must not wait for it.

## Scope

Move the poll from the server to the browser.

1. `GET /d/{name}/version` — a small JSON endpoint returning the same two
   facts the stream loop reads: the dataset version and the publish pointer.
   Same access check as the page; fails closed identically.
2. The page's shim polls it instead of holding an `EventSource`. The baseline
   is embedded at render time, not learned on the first poll, so a refresh
   landing between render and first poll is still seen.
3. The `stream` route and `gdash_app.events` go. Leaving an endpoint whose
   only effect is to pin a worker would leave the ceiling reachable on
   purpose by any viewer allowed to see the dashboard.

## Verification

- A ceiling suite that fails if the law returns: with the default single
  worker and several viewers behaving the way the served page tells them to,
  every request is answered.
- The notifications the stream carried must still arrive: a refresh performed
  by another process reloads an open page; a publish shows the notice and does
  *not* reload (design §7 — a pinned viewer is not yanked).
- Existing e2e and multi-worker suites updated at the point where they drove
  the stream, not deleted.

## Deliberately not built

- Any change to the refresh mechanism, the version file, or the rename-swap.
  The signal is unchanged; only its carrier moves.
- A configurable poll interval. One number in one place until there is a
  reason for two.
- TLS. Still blocked on the platform (`gdash8_platform_report_tls.md`).

## Owed to the maintainer

Design §5's sentence names SSE as the carrier. After this phase it is wrong in
its mechanism and right in its principle. The correction is the maintainer's
to make, not this phase's to make silently.

---

## DONE

Delivered. `docs/gdash11_findings.md` has the detail.

- `GET /d/{name}/version` returns the dataset version and the publish pointer,
  behind the same access check as the page. The `stream` route and
  `gdash_app.events` are gone.
- The page polls it every five seconds, from a baseline embedded at render
  time and passed through the script element as an escaped JSON literal.
- `tests/run_ceiling.sh` — 11 assertions at the **default** worker count.
  Verified by mutation: re-pinning the worker reproduces the original `000`.
- `tests/shim_check.js` — 10 assertions, the first anywhere that runs the
  page's own JavaScript.
- `run_workers.sh` lost its retry loop; its two held streams are eight
  concurrent pollers, and the "flake" it apologised for was the ceiling.
- Operations §5 rewritten around what a request costs (28 ms poll, 57 ms
  page), measured rather than asserted.

Suite: 29 suites, 911 in-process, 21 multi-worker, 11 ceiling, 9 concurrency,
186 end-to-end (10 of them the shim, run under node) — green. Opt-in runners unchanged.

### Deliberately not built

A configurable poll interval; a cache to make the poll cheaper than 28 ms;
TLS (still blocked on the platform).

### Owed to the maintainer

Design §5 names SSE as the carrier for global events. After this phase that
sentence is wrong in its mechanism and right in its principle. The design
document was not touched.
