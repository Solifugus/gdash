# For the gbasic session — two from gdash's deployment phase

## 1. `web.configure` accepts cert/key and `serve` ignores them

**A server configured for TLS listens in cleartext.** The configuration is
accepted, stored, and silently not applied, so the operator believes the thing
is encrypted and it is not.

Found at `ca5df46` while wiring gdash's TLS surface, which the reference says
is exactly what `configure` is for: "a value known only at run time — a port
from `/etc`, a worker count from the environment — reaches the runtime without
the head giving up its literals."

## Measured, both ways, same certificate

```basic
server a( port: 8790, cert: "/tmp/cert.pem", key: "/tmp/key.pem" )   ' in the head
server b( port: 8791 )                                              ' via configure
```

```
cert/key IN THE HEAD          https=200   http=000     TLS on, cleartext refused
cert/key VIA web.configure    https=000   http=200     TLS OFF, serving cleartext
```

## Where it goes wrong

`configure` is doing its half. The merged declaration carries them:

```
options keys: cert,key,port
options.cert = /tmp/cert.pem
```

So `serve` is reading the TLS pair from the **pre-registered block** rather
than from the declaration it was handed. `port` and `workers` from the same
merge do take effect, which is what makes this hard to notice: everything else
you configure works.

## Why this one is worse than an ignored option

The other options fail visibly — a wrong port is a connection refused, a wrong
worker count is a number in `ps`. This one fails *invisibly and in the
direction of less security*. Nothing in the server record says whether TLS is
on:

```
serve returned keys: _webserver_id,address,held,port,requests,responses,running
```

so a caller cannot even check. gdash **refuses to start** when TLS is
configured rather than serve cleartext while printing "TLS from …", because an
operator who configured TLS and got cleartext is worse off than one who was
told to use a reverse proxy: the first believes they are encrypted.

## What would help

1. **Make `serve` read `cert`/`key` from the declaration it is given**, as it
   already does for `port` and `workers`. That is the fix.
2. Failing that, **refuse them in `configure`** the way `host` is refused —
   with a reason. An option accepted and ignored is worse than one rejected,
   and this is the option where that gap is a security property.
3. Either way, **a way to ask whether TLS is on** would let a caller verify
   rather than trust. A `tls` boolean on the record `serve` returns would be
   enough; gdash would check it at startup and refuse on a mismatch.

gdash is not blocked — a reverse proxy is the usual deployment anyway — and it
has a test that will go red when this is fixed, which is how it will notice.

---

## 2. `on drain` does not fire under `workers: N`

The reference says "`on drain ... end on` runs once when draining begins", and
`serve` with `workers: N` "ticks until asked to stop, then drains". Measured at
`ca5df46`, SIGTERM to the supervisor one second into a four-second handler,
repeated:

| workers | in-flight request | `on drain` fired |
|---|---|---|
| 1 | completed, 200, full body | **yes** |
| 4 | completed, 200, full body | **no** |
| 1 | completed, 200, full body | **yes** |
| 4 | completed, 200, full body | **no** |

**The important half is good news and worth saying first**: an in-flight
request completes in both shapes. A four-second handler interrupted at one
second still returned 200 with its whole body, and every process exited. That
is a real graceful shutdown and callers get it for free.

The hook is the inconsistent part. It runs single-process and not under the
supervisor — which is the shape anything real deploys in, so a caller who
tested at `workers: 1` would ship a hook that never runs.

gdash **is not affected and is not asking for a fix on its own account**:
workers share no in-memory state by design (§5), so there is nothing for gdash
to flush at shutdown, and it deliberately adds no drain hook rather than adding
one that fires in only one configuration. Reported because the next caller will
have state to flush, will test it single-process, and will be wrong.

Either the hook should fire in both shapes, or the reference should say which
one it means.
