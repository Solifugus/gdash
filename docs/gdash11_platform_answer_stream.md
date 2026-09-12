# Answer — a stream handler that does not hold its worker (GDASH-11)

**From:** gbasic, at `3e69896`
**Status:** the premise is wrong, the conclusion is right, and the real gap is
bigger than the ask.

## 1. A stream handler does not have to hold its worker — it never did

The shape in the ask keeps the handler running:

```basic
stream "/d/{name}/events"( req )
    while alive and ticks < 7200
        sleep(0.5)
        ...
    end while
end stream
```

That holds a worker because **the handler is still executing**, not because it
is a stream. The connection outlives the handler, so a stream is kept alive by
**parking** the request and returning:

```basic
stream "/events"( req )
    e = web.emit(req, web.sse_event("open"))
    append(G.streams, req)
    return 0
end stream

post "/notify"( req )
    alive = []
    for each s in G.streams
        if web.emit(s, web.sse_event(req.body)) then
            append(alive, s)
        end if
    end for
    G.streams = alive
    return { status: 200, body: "ok" }
end post
```

Measured against your own test, at `3e69896`, `workers: 2`:

```
port 43843, workers=2
6 streams open on 2 workers. next request:
pong
pong
pong
```

Six parked streams on two workers, and `/ping` answered three times. Your
adoptability requirement 1 is met today. So is requirement 2: `web.emit`
returns false for a departed client, which is what the reaping loop above uses
— `tests/run_web_stream.sh`'s `stream_disconnect` tier asserts exactly that.
And requirement 3 is trivially met, since nothing changes.

`tests/web_server_block/block_stream.bas` has used this shape since PLAT-WEB-5,
and `run_web_stream`'s `SSE_BROADCAST` tier pokes a stream parked by one
request from a *second* connection — which is only possible because the first
handler returned. **None of that was in `docs/reference.md`.** The knowledge
lived in fixtures; the reference documented `emit`/`finish` and never stated
that a stream handler must return. Your extrapolation was the reasonable one
from what was written. That is fixed at `3e69896`, with the parked shape, the
reaping idiom and the limits below written down.

## 2. Why you were still right to poll

Parking is not enough for gdash, for two reasons, and both are worth having on
the record before anyone moves that route back.

**A parked stream belongs to the worker that accepted it.** `workers: N` is N
separate processes, so `G.streams` is N separate lists. Measured, `workers: 2`,
four streams open, accepts split 3/1:

```
POST /notify -> "worker poked 3"    (reached streams 1,2,3)
POST /notify -> "worker poked 1"    (reached stream 4)
POST /notify -> "worker poked 1"    (reached stream 4)
POST /notify -> "worker poked 1"    (reached stream 4)
```

Each poke reached only the streams in its own process. That is the same
isolation that makes `spawn` a fork+exec and stops a principal crossing it, so
it is not a defect — but a broadcast that must reach *every* viewer either runs
at `workers: 1` or needs a channel between workers, which `web.pool` does not
provide.

**Nothing wakes a parked stream on a schedule.** Every source the event loop
polls is request-, reply- or transfer-driven: `server.requests`,
`inbox.messages`, `http.events`. There is no timer and no filesystem source.
gdash's truth is a version file written by whichever worker handled the write —
so even within one process there is nothing to notice the change and poke. Your
table's first row (latency to notice a refresh) cannot be improved by parking
alone.

Polling was the right call and remains the right call for gdash today.

## 3. What the actual gap is

Not "a handler that can wait". A handler that waits is the thing to *avoid*;
the platform already lets it return. The two missing pieces are:

1. **A periodic source on the event loop** — something a program can watch that
   fires on a clock, so a parked stream can be poked without a handler
   blocking. This is broader than streams: gBASIC has no way to run periodic
   work on the event loop at all.
2. **A way to reach parked streams across workers** — or an explicit statement
   that broadcast means `workers: 1`, which is what the reference now says.

**Item 1 shipped the same day**, as `timer` (gbasic `e56daa0`,
`docs/timer_design.md`):

```basic
t = timer.every(0.5)

watch(timer.ticks)
    while count(timer.ticks) > 0
        ev = take_first(timer.ticks)
        poke_the_streams()
    end while
end watch
```

`timer.every` / `timer.after` / `timer.cancel`, delivered through
`watch(timer.ticks)`. No `load` needed. Ticks are **coalesced, never caught
up** — a handler slower than the interval loses ticks rather than producing a
burst — and each tick carries `skipped`, the number of intervals not delivered
since the last one, so a poller can tell whether it is keeping up.
`tests/run_timer.sh`'s `STREAM` tier is your use case exactly: a parked stream
receiving 15 timer-driven events in 3s while `/ping` is still answered.

**Item 2 did not ship and is not planned.** A broadcast that must reach every
viewer still means `workers: 1`, and the reference now says so.

For gdash that means the route is movable back, with one thing to check first:
your version file is written by whichever worker handled the write, and a timer
poking parked streams reaches only the streams **in its own worker**. At
`workers: 1` that is fine. Above 1 the polling endpoint remains correct, and
nothing here asks you to change it.

One defect fell out of building this and is worth knowing if you do move the
route: a program with a server **and** a live timer never exited on SIGTERM —
the server drained and the timer held the event loop open forever. Fixed in the
same commit. It was pre-existing and general (a watched `inbox.messages` did the
same), so any gdash worker that drains is better off at `e56daa0` or later.

## 4. One correction to the ask's measurement

```
workers=1  streams=1   next request: no response after 5s
workers=2  streams=2   next request: no response after 5s
workers=4  streams=4   next request: no response after 5s
```

"Concurrent viewers = workers − 1, exactly" is a property of the `while
sleep` handler, not of streams. With the parked shape the number of concurrent
viewers per worker is bounded by open descriptors, not by workers. Worth
restating in GDASH-11 so the figure is not carried forward as a fact about
`stream`.
