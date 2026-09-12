# Platform ask — a stream handler that does not hold its worker

**From:** gdash, GDASH-11
**Status: ANSWERED** — see `gdash11_platform_answer_stream.md` (gbasic
`3e69896`, `e56daa0`) and `gdash11_findings.md` G11-13.

**The premise below is wrong.** A stream handler never had to hold its worker:
the connection outlives the handler, so a stream is kept alive by *parking* the
request and returning. gdash's handler looped in `sleep(0.5)` and never
returned, and that is what held the worker. The shape had existed since
PLAT-WEB-5 and lived in a test fixture rather than the reference, which is now
fixed.

What shipped in response was `timer` — periodic work on the event loop, the
genuinely missing piece. What did **not** ship, and is not planned, is
cross-worker reach: a parked stream belongs to the worker that accepted it, so
a broadcast to every viewer means `workers: 1`. gdash cannot take that, so it
stays on polling — permanently, and for that reason rather than the one argued
below.

The document is left standing as the record of a wrong question asked well.

---

## What gdash did, and why it stopped

A dashboard page held an SSE stream so that a refresh reaching the server also
reached the tab. The handler looked like this:

```basic
stream "/d/{name}/events"( req )
    ...
    while alive and ticks < 7200
        sleep(0.5)
        now_v = gdash_store.read_version(vfile)
        if now_v != seen then
            alive = web.emit(req, "data: refresh" + chr(10) + chr(10))
        end if
        ticks += 1
    end while
end stream
```

That is the shape PLAT-WEB's own documentation suggests, and it works. Its
cost is that the handler never returns, so the worker never comes back.
Measured at gbasic `ca5df46`:

```
  workers=1  streams=1   next request: no response after 5s
  workers=2  streams=2   next request: no response after 5s
  workers=4  streams=4   next request: no response after 5s
```

Concurrent viewers = workers − 1, exactly. The default worker count is 1.

gdash replaced the stream with the browser polling a small JSON endpoint every
five seconds. That solved gdash's problem completely and is the right thing
for gdash to have done, so **nothing here is urgent**.

## The ask

A way for a stream handler to wait for something without occupying a worker
while it waits. Roughly: the handler yields, the runtime keeps the connection,
and the handler resumes on the event.

The shape suggested by `watch(inbox.messages)` looks close to it —
a handler that suspends on a watched source rather than looping on `sleep`.
Whether that generalizes to a stream handler and a filesystem source is the
platform's call, not gdash's.

## Why it would still be worth having

Polling is a real trade, not a free win:

| | held stream | browser poll |
|---|---|---|
| latency to notice a refresh | immediate | up to 5 s |
| requests while nothing happens | none | 0.2/s per open tab |
| workers occupied per viewer | 1 | 0 |
| behind a proxy | needs stream-aware config | ordinary requests |

gdash took the trade because the third row was fatal and the others are not.
An application where the first row matters — a live console, a queue depth, a
running job's output — cannot take that trade, and in gBASIC today it has no
other option.

## What would make it adoptable

1. **The worker is genuinely free while the handler waits.** The test is the
   one above: N suspended streams on N workers, and request N+1 answered.
2. **Departed clients are noticed.** `web.emit` returning false is the only
   liveness signal there is; whatever replaces the loop needs an equivalent,
   or a suspended handler for a closed tab leaks until some ceiling.
3. **`serve` and `web.configure` unchanged otherwise.** gdash would move one
   route back and delete a `setInterval`.

## Not asked for

- Anything about SSE framing; that part was fine.
- A pub/sub or message bus. The filesystem is the right place for this
  application's truth, and design §5 depends on its being somewhere every
  worker can read independently. What is wanted is a way to *wait* on it.

---

Filed here rather than in the gbasic repo, per gdash's house rule: platform
gaps found while building gdash are findings for the report and candidates for
gbasic's DOGFOOD.md, entered only through that repository's own process.
