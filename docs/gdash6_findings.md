# GDASH-6 — Findings

**Status:** step-0 complete. It passes, which was not the expected outcome.
**Platform:** gBASIC `36cb538`. Everything here was executed, not read.

---

## G6-1 — design §5's shared-nothing claim is true, and this is the first time anyone checked

Every test, every end-to-end run and every phase from GDASH-0 through GDASH-5
executed against **one worker**. `server gdash_web( port: 8780 )` declares no
`workers:`, and the default is 1.

Design §5 is built on a claim that had therefore never been executed: workers
share no in-memory state, per-viewer interactivity rides request/response, and
SSE carries only global events observed through the filesystem. Sessions are
files and the pin is a cookie *because of* that claim. It is load-bearing for
the whole architecture and it was, until now, a design intention.

Run with `workers: 4` — a supervisor plus four children spawned via
`process.self()` — against a real root, a real account and real data:

| what was checked | result |
|---|---|
| sign in on one worker, then 30 requests spread across all four | session seen 30/30, missed 0 |
| CSRF token read 8 times across workers | 1 distinct value |
| 8 concurrent dashboard renders | 200 × 8 |
| **four concurrent SSE streams, refresh performed by a separate CLI process** | **all four saw `data: refresh`** |

That last row is the one that matters. Four streams held open on four
different workers each observed a data change made by a fifth process that
shares nothing with any of them but a directory. That is the design's central
mechanism working, observed rather than asserted.

**Nothing needs to change for gdash to run multi-worker.** The phase opened
expecting to find a wrong ruling and found a right one. Recorded at length
anyway, because "we believe this works" and "we have seen this work" are two
facts, and this project has been bitten three times by treating two facts as
one (G4-10, G5-4, G5-8). It is now the second kind.

## G6-2 — the readiness contract changes with `workers: N`, and gdash's startup line is wrong for it

`serve(sv)` has two shapes and gdash has only ever met one.

- **`workers: 1`** — `serve` binds, returns the live server record, and
  `main` continues. gdash prints `gdash: listening on 8780`.
- **`workers: N`** — `serve` becomes the supervisor: it binds with `hold:`,
  prints **`PORT <n>`** itself, spawns N copies of the program, and **does not
  return until drain**. gdash's own `listening` line is never printed at
  startup; it would print at *shutdown*, if the process survived to reach it.

Observed with `workers: 3`:

```
gdash: mode=root config=… state=… cache=… log=… run=…     <- once
PORT 8780
```

Exactly **one** startup line and **zero** `listening` lines. The workers'
`main` output does not reach the supervisor's stdout at all, so design §6's
"resolved roles are logged at startup" is satisfied once by the supervisor and
the workers are silent — which is tidy, and also means a worker-side startup
problem would not appear in that log.

Two things follow, and both are this phase's to fix rather than to report:

1. **Every readiness check gdash ships greps for `listening`** — `run_e2e.sh`
   and `run_ldap.sh` both do. Neither would ever start under `workers: N`.
   A readiness check must accept whichever line this build's shape produces,
   or gdash must print its own line in both shapes.
2. **GDASH-8's systemd unit will depend on this**, and a unit whose readiness
   probe works only at `workers: 1` is a unit that breaks the moment an
   operator tunes it.

## G6-3 — `secret_of` is the only durable write in gdash that is not atomic

gdash has one rule for writing a file that matters, applied everywhere: write
a `.tmp` sibling, then `atomic_replace`. `gdash_users.save` does it (and
`chmod`s the temp *before* the rename). `gdash_session_files.put` does it.
`gdash_publish` does it. The dataset swap is a single POSIX rename and design
§2 makes it an invariant.

`gdash_app.secret_of` does not:

```basic
fresh = crypto.random_token(32)
nf {file} = path
write(nf, fresh)          ' straight to the destination
...
return fresh              ' its own value, not whatever won the race
```

Two consequences under N workers with no secret file yet. Two workers can each
generate a secret and each return *its own* rather than re-reading what landed;
and a concurrent reader can see a partially written file, because there is no
rename to make the write appear all at once.

**It did not reproduce.** The secret was deleted and 24 simultaneous requests
fired, three rounds, and every round returned a single distinct CSRF token. The
window is small and the first request usually wins it outright.

Recorded and fixed anyway, and the reason is not the repro. The failure it
would produce is benign — a token minted under one secret is refused by a
worker holding another, which surfaces as "That form expired" and **fails
closed**. What is not benign is a file gdash writes non-atomically in the one
module where every other write is atomic, in security-relevant code, with
nothing saying why it is different. It is different because it was written
before anyone ran two workers.

## G6-4 — `web.dispatch` exists, gdash has never used it, and it cannot quite be used

`web.routes(sv)` returns the route table as flat data and
`web.dispatch(sv, req)` runs a full request — host dispatch, route matching,
path captures, static fallback — **with no socket**. Verified against a probe:
`{ method, path, headers, query, form, cookies }` in, the handler's response
record out, `req.params.name` captured, and an unmatched path answering 404.
`headers` is required; omitting it raises inside `web.bas`.

**But a `server` block cannot be loaded from another file.** `load x from
"file_with_a_server_block.bas"` raises, and gbasic's own
`tests/run_web_server_block.sh` declares its blocks in the same file as the
test. So gdash's route table cannot be dispatched from `tests/`, and
duplicating the block in a test would create a second source of truth for
routing — the thing gdash refuses everywhere else.

The route table therefore stays end-to-end's job, which is what end-to-end is
genuinely good at: proving the wiring exists. **The handlers do not.** They are
ordinary library functions taking a `req` record, and `gdash_app`'s file header
has said since GDASH-0 that they are "kept out of the server block so the same
logic is directly testable without a socket". Nothing ever tested them that
way. 1083 lines, every authorization decision in the product, covered only by
`curl` and substring matching.

## G6-5 — the root travels in the environment, which is why nobody tested the handlers

`gdash_app._root_of(req)` ignores `req` and reads `env("GDASH_ROOT")`. That is
correct and should not change: handlers cannot see argv (PLAT-WEB), and taking
a root *from the request* would let a client choose which directory tree gdash
reads — a path-traversal hazard dressed as a convenience.

The consequence is that an in-process handler test must export `GDASH_ROOT`
rather than pass a path, which is a different shape from every other suite in
`tests/`, all of which take their scratch root as `args[0]`. That difference is
small, and it is enough friction to explain why the test that the header
promised was never written.

## G6-6 — 133 end-to-end assertions are substring matches, and three have already lied

`run_e2e.sh` asserts with `grep -F` against whole HTML pages. That has produced
a false result three times in three phases:

- `hasnt "$page" "gdash-error"` — the string is in the stylesheet on every page.
- `hasnt "$pub" "gdash-preview"` — same, and same stylesheet.
- an assertion on `$5,339.65`, which appeared twice on the page for two reasons.

Each was caught because the assertion failed when it should have passed. **The
dangerous direction is the other one**, and it is not detectable by running the
suite: a `has` that matches a stylesheet rule, a script fragment or an
unrelated visual passes forever while testing nothing. Assertions that can pass
for the wrong reason read as coverage and are worse than absent ones.
