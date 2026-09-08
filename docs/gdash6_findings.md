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

**That paragraph originally said "it did not reproduce", and that was wrong** —
see G6-9. The measurement counted lines in a file holding 24 newline-less JSON
responses, so it reported "1 token" whether one request or twenty-four had been
answered. Measured properly, against the pre-fix code, **round 5 of 5 produced
two distinct secrets**: the race is real, it reproduces roughly one attempt in
five, and the test that catches it now runs six rounds for that reason.

The failure it produces is benign — a token minted under one secret is refused by a
worker holding another, which surfaces as "That form expired" and **fails
closed**. What is not benign is a file gdash writes non-atomically in the one
module where every other write is atomic, in security-relevant code, with
nothing saying why it is different. It is different because it was written
before anyone ran two workers.

Fixed: creation is serialized with the same advisory-lock idiom
`gdash_refresh` uses, the state is re-read **inside** the lock so the second
worker through finds the first one's secret rather than replacing it, and the
write is temp + `atomic_replace` like every other durable write in gdash.

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

## G6-7 — `workers` must be a number literal, so the count cannot be configured

**Closed at gbasic `ca5df46`** by `web.configure`, which merges deployment
settings into a declaration without the head giving up its literals. gdash
reads `GDASH_WORKERS`; the generated-source workaround below is gone. The
finding stands as written, including the part about the error message pointing
at `webserver.listen` — which the platform confirmed was true for port and
address and false for workers, and has fixed.

```
parse error: server 't': option 'workers' must be a number literal -- head
options are literals, so the block stays statically checkable; computed
configuration belongs to webserver.listen
```

The constraint is deliberate and the message names its own escape hatch, but
the consequence is gdash's: **an operator cannot tune the worker count without
editing source.** For a product whose GDASH-8 deliverable is "stand it up in an
afternoon", that is a real gap, and it has three possible answers — ship a
literal a packager patches, drop the `server` block for `webserver.listen` and
lose its static checking, or ask the platform for a third way. It is GDASH-8's
decision, recorded here because this is where it was found.

It also shaped this phase's test: rather than commit a second copy of the
routing table carrying a different literal — two sources of truth for routing,
which gdash refuses everywhere else — `run_workers.sh` copies `src/` to a
scratch directory and rewrites the literal there.

## G6-8 — a path literal outside the resolver, pointing out of the repo

Copying `src/` somewhere else is what found it:

```
could not load library file: /tmp/…/src/../../gbasic/stdlib/chart.bas
```

`gdash_render.bas` loaded the chart library by a **relative path into the
sibling gbasic checkout**, and `tests/overrides_probe.bas` did the same.
CLAUDE.md says it plainly: "All paths go through the resolver. No path literal
outside the resolver module." This was one, and it had been there since
GDASH-1.

It was invisible for five phases because every process gdash starts is started
from the repository root, where `../../gbasic/` happens to exist. The
consequences it was hiding:

- **gdash could not be installed anywhere.** An FHS install would put
  `gdash_render.bas` in `/usr/lib/gdash/` and have it look for
  `/usr/lib/gbasic/stdlib/chart.bas` — GDASH-8's whole phase, blocked by a
  string.
- **gdash could not be relocated at all**, which is why the multi-worker test
  could not run until it was fixed.

The fix is one word: `load chart`. `chart.bas` is in the installed stdlib
alongside `web`, `sqlite` and `crypto`, all of which gdash already loads
unqualified. The path literal was not just wrong, it was unnecessary.

**This is the finding that justifies the phase.** No amount of reading would
have produced it; it took moving the code somewhere it had never been.

## G6-9 — three measurement bugs, in the harness written to catch measurement bugs

G6-6 says 133 end-to-end assertions can pass for the wrong reason. While
writing the suite that opens this phase, I wrote three more:

1. **`grep -c` on newline-less output.** `/whoami` answers compact JSON with no
   trailing newline, so 24 concurrent responses land on **one line**. `grep -c`
   reported 1 whether one request or twenty-four had been answered, and a
   greedy `sed` returned only the last token. Both read as "one worker
   answered, one secret" — a green result from a test that measured nothing,
   and it is what put the wrong sentence in G6-3.
2. **A bare `wait` waits for the server.** `wait` with no arguments waits for
   every background job, including the server the test started, so the suite
   hung for 4m40s. Worse, `wait` on named pids *inside a command substitution*
   spun, emitting 7.8 GB of "not a child of this shell".
3. **`sleep 1` used as readiness.** A stream that connects after the refresh
   reads the new version as its baseline and never reports a change. The fix
   is to wait for each stream's `event: hello` — the same lesson as G5-8, where
   an open port was mistaken for a working service, and G4-10 before it.

And a fourth that is not about measurement but about editing: **a
`str.replace` whose pattern does not match silently changes nothing.** Two
"fixes" in this file were applied to a pattern that had drifted, reported
success, and left the bug in place; the one edit that carried an `assert`
caught it immediately. Every edit in this phase now asserts.

None of these were caught by the suite passing. They were caught by the suite
behaving strangely — hanging, or being too fast, or producing an implausible
number. That is not a reliable detector, and it is precisely G6-6's point
turned back on its author.

## G6-10 — concurrent SSE streams do not establish reliably, and the ceiling is unresolved

**Closed in GDASH-8 (G8-9).** The ceiling is exactly the worker count: an open
dashboard holds a worker for as long as it is open. The measurement below was
the wrong one -- counting how many streams established confounded worker
pinning with curl buffering. The right one is to hold every worker with a
stream and then ask for an ordinary page, which is not answered at all.

Every live stream pins a worker for its lifetime — `gdash_app.events` says so
in a comment, and design §5 names the ceiling. What was not known is the number.

Measured at six workers (seven processes), asking for N streams at once:

| requested | established |
|---|---|
| 2 | 2 |
| 3 | 2 |
| 4 | 3 |
| 5 | 3 |
| 6 | 2 |

It does not scale with the worker count, and an ordinary `GET /` still answered
**200** while five streams were held — so the workers are not simply exhausted.
Even two streams fail to establish about one attempt in four at four workers.

**I could not separate the causes** with the tools to hand: worker assignment,
`curl`'s output buffering when redirected to a file, and connection
establishment under the pool are all candidates, and a shell is a poor
instrument for telling them apart. Rather than guess, the suite proves the
property with **two** streams and retries only the *establishment* — never the
observation — reporting the attempt count when it retries.

This matters beyond the test. If a dashboard holds a stream while open, the
number of dashboards that can be open at once is bounded by something gdash
does not currently understand. The plan already assigns "the SSE worker-pinning
ceiling stated plainly" to the deployment phase; this is the evidence that the
sentence needs a number behind it, and that finding the number is real work
rather than a documentation task.

## G6-11 — a library may define the same function twice, and the later one silently wins

gBASIC accepts this without a warning:

```basic
library x
    function f()
        return 1
    end function
    function f()
        return 2
    end function
end library
```

`x.f()` returns 2. No error at parse, none at load, none at call.
`library_collisions()` does not report it either — correctly, since it answers
a different question: which name is defined by more than one *library*. Within
one library there is no check at all.

It cost real time here. Threading the new directory seam through
`gdash_auth_ldap` meant rewriting call sites of `bind_as(cfg, dn, password)`,
and the *definition* line `function bind_as(cfg, dn, password)` contains that
same text — so the mechanical rename produced a second, stale definition that
still called the live `ldap` module. The stale one was later in the file, so it
won. Every bind in the hermetic tests went to a real directory that was not
running, and the symptom — `unreachable` from a test double that had just
answered `ok` when called directly — reads exactly like a broken double.

**Fixed in the platform at gbasic `f21486e`**, as an error, with a message
better than the lint that reported it:

```
function 'refusal' is defined twice in library 'gdash_auth'
  -- the first, at line 39, would be unreachable
```

`tests/duplicate_defs.py` was written to catch this and has been **deleted**.
A check that only restates what the compiler enforces is noise in a suite, and
the compiler's version names both lines and fires at parse time rather than
needing a grep pass. The finding stands as the record of why the rule exists.

## G6-12 — mutation testing found a hollow assertion the suite could not

The brief requires every new test to be observed failing. Five deliberate
breakages were introduced into `gdash_auth_ldap` and the directory suite run
against each:

| mutation | caught |
|---|---|
| forget to close the user's connection | yes |
| a service-account bind failure reported as success | yes |
| an empty password sent to the directory after all | yes |
| bind to the DN the filter implies, not the one returned | yes |
| **memberof silently falls back to a search when the attribute is empty** | **no** |

The one that survived is the one the whole G5-4 ruling rests on. The test
asserted "the memberof strategy resolves NO groups", and it did — but the
scripted directory had no groups to find by any route, so the assertion would
have passed for a directory that simply had none. It proved the absence of
data, not the discipline of the strategy.

Fixed by giving that test **the same directory the `search` tests use** —
`group_base` configured and the group rule present — so a member= search would
find two groups and memberof must still find none. The mutation is now caught
with `expected <0> got <2>`.

Worth stating plainly: the suite was green, the assertion was well-named, and
it was hollow. Nothing but deliberately breaking the code would have shown
that. Two other assertions were found to *crash* rather than fail — indexing
`[0]` into an empty array kills the run and takes every later assertion with
it — which is the same lesson in a different costume.

## G6-13 — `git checkout` after a mutation restores HEAD, not your work

A small process finding, recorded because it produced fifteen minutes of
convincing nonsense. The mutation loop restores each file with
`git checkout -- <file>` between runs. An *uncommitted* fix in that same file
is restored away too — so the duplicate `bind_as` of G6-11, which had been
removed but not committed, came back after the first mutation and every
subsequent result was measured against broken code.

The rule is simple and now followed: **commit before mutating.** A mutation
run is only meaningful against a known-good baseline, and "known-good" has to
mean committed, not merely edited.

## G6-14 — the qualification rule cost gdash five call sites, and my estimate missed them

gbasic `554e22e` made a function from another library require its prefix. I
priced that change for the platform before it shipped, from gdash as a real
consumer: **zero** bare cross-library calls among gdash's own sixteen
libraries, against **501** bare *self*-calls that a stricter reading would
have forced. The measurement argued for the rule that shipped.

The estimate was right about gdash's own libraries and **wrong about the
platform's**, which I said at the time it could not see:

```
src/gdash_server.bas:104: serve(gdash_web)      -> web.serve(gdash_web)
src/gdash_app.bas    x4 : emit(req, ...)        -> web.emit(req, ...)
```

Both are `web` functions, and `serve` was documented as "reachable
unqualified". Neither file loaded `web` at all — the server block supplied
them implicitly — so both needed a `load web` as well. Five call sites, two
loads, twenty-six suites green afterwards.

Worth recording for the shape rather than the size. The scan compared gdash's
libraries **against each other**, because that is the inventory it could build
from source; native and stdlib modules were outside it and were named as
outside it. The gap in the estimate was exactly the gap I declared. That is
the good version of being wrong — but a caveat stated in a report is still a
hole in the number, and the number is what gets quoted.

## G6-15 — the record validator crashed on author JSON that was not the shape it expected

The front door for author-supplied JSON, and it could be knocked down with a
valid JSON document:

```json
{ "format": 1, "name": "b", "datasets": {}, "visuals": {}, "tabs": ["oops"] }
```

`tb["name"]` on a string raises. Nine sites had the same defect — four
indexing a container element without asking what it was (`datasets[dn]`,
`visuals[vn]`, `controls[cnm]`, `tabs[i]`), four calling `keys()` on something
that might not be a record (`params`, `controls`, a dataset's `columns`, an
encoding's `formats`), and `check()` itself, which indexed the record before
establishing it was one.

**This was not merely a CLI annoyance.** `load_file` calls `check`, and
`_load_dashboard` calls `load_file` on every request — so a hand-edited draft
of the wrong shape would raise inside a handler, and a raise inside a handler
kills the worker (PLAT-WEB, let-it-crash). A published record cannot reach
this state, because publish validates first; a draft is exactly the thing an
author edits by hand, and the draft is what gets served until the first
publish.

All nine now refuse with a message, pinned in the golden. Two of the guards
were mutation-tested by removing them: both crash the suite without them,
which is the proof the assertions are load-bearing rather than decorative.

Worth naming the pattern, because it is the same one as G6-11 and G5-9: the
failure was not a wrong answer but a **raise where an answer belonged**, in
code whose entire job is to report what is wrong with something.

## G6-16 — a NUL truncates a record key, silently

```basic
r = {}
r["a" + chr(0) + "b"] = 1
print(len(keys(r)[0]))        ' 1
```

gBASIC strings are binary-safe and the string builtins have been since
`36cb538` (G5-9), but a record **key** carrying a NUL comes back from `keys()`
truncated at it, with no error. So a dataset named `"a\0b"` in a record file is
really named `"a"` by the time anything validates it — a legal identifier, and
not the name the author wrote.

Found by an adversarial assertion that was wrong about gdash: the test expected
such a name to be refused, and it was accepted, because by then it was no longer
that name. No gdash change; it is asserted so the behaviour is visible rather
than surprising, and it belongs with the G5-9 report as the remaining corner of
the same question.

## G6-17 — a dataset named for a SQL keyword is accepted, by decision

`legal_identifier("select")` is true — it is a legal identifier lexically. The
name becomes a table name, so a visual reading `from select` fails at query
time with a sqlite syntax error rather than at load time with a message about
the record.

**Not fixed, deliberately.** A keyword list is dialect-specific, long, and a
policy gdash would then own forever; several plausible names (`order`,
`group`, `values`) are also reasonable business words. The failure is immediate,
visible on the author's own first refresh, and names the spot. Recorded with an
assertion so the decision is a decision rather than an oversight.

This is the one place the adversarial pass found something and left it alone,
and the difference from G6-15 is worth stating: that one raised where an answer
belonged, this one answers — just later than design §1 would prefer.
