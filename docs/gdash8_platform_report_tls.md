# For the gbasic session — `web.configure` accepts cert/key and `serve` ignores them

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
