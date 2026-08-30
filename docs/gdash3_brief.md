# GDASH-3 — Draft, publish, snapshots: phase brief

**Status:** COMPLETE. All seven §5 criteria met; at the review boundary.
Findings in `gdash3_findings.md`; DONE note in §7.
**Narrows:** the GDASH-3 paragraph of `gdash_development_plan.md`.
**Authority:** `gdash_design.md` outranks this brief. The findings of GDASH-0,
GDASH-1 and GDASH-2 are inputs, not open questions.

GDASH-2 left this phase half-scaffolded on purpose: `gdash_paths.publication`
already reads a `current` pointer and resolves it to a snapshot, and
`tests/e2e_publish.py` writes that pointer by hand because publish did not
exist. GDASH-3 replaces that file with the real thing and inherits a read side
that is already exercised end to end.

---

## 1. Step-0 verification

Five premises, checked against gBASIC `e8b3549`.

- **V1 — symlink creation: ABSENT, and that settles the pointer's shape.**
  `real_path` resolves symlinks and `file_type` follows them, but nothing in
  the interpreter *creates* one — there is no `symlink` builtin in `eval.c` or
  the reference. GDASH-2 chose a regular file naming a snapshot leaf and
  confined it to one function so this phase could rule otherwise cheaply. It
  may not, and the caveat closes: the file **is** the design.
- **V2 — cookies round-trip through the `server` block: PASSES.**
  `req.cookies` is a parsed record (verified: two cookies in, both keys out,
  and an empty record when none are sent) and a response's `cookies` array
  emits one `Set-Cookie` each. So §7's session pinning is buildable now,
  without GDASH-4's session store — see §2.4 for what that does and does not
  buy.
- **V3 — a diff facility: ABSENT.** No builtin, nothing in `stdlib`. So the
  snapshot diff is either shelled out to `diff(1)` or hand-rolled. **Ruling:
  hand-rolled.** A product whose pitch is "stand it up in an afternoon" should
  not have a headline feature that depends on a binary being in the image, and
  design §6's own deployment guidance (`ProtectSystem=strict`, a dedicated
  user, a minimal container) describes exactly the environments where a shell
  out is least safe to assume.
- **V4 — the atomic repoint is already proven.** `atomic_replace` over the
  pointer file is the same single `rename(2)` GDASH-0 uses for the version
  file and GDASH-2 for dataset state. No new mechanism, and the same
  guarantee: a reader sees the old pointer or the new one, never a torn one.
- **V5 — the suite is green on current gBASIC.** 15 suites, 318 in-process
  assertions plus 60 end-to-end; live Postgres 8/8. This includes `2263ed2`
  ("a raise in an argument abandons the call"), a real change to the semantics
  gdash's `on error goto next` idiom sits on, so it was run rather than
  assumed.

**A correction to GDASH-2's own findings** came out of this step and is
recorded in place: G2-7 said one documentation line was wrong about
`file_type`. In fact the builtin is documented **twice** and the two entries
disagree; I read the older, wrong one and did not check for a second. The
cross-repo item is therefore "merge two entries", not "reword one".

## 2. Scope — the narrowing

### 2.1 Publish

Draft → `snapshots/NNNN.json` (zero-padded, next = highest + 1) → atomic
`current` repoint → audit event. Snapshots are immutable and all are kept:
they are small text and design §7 says to keep them.

**A record that does not validate cannot be published.** Publish runs the same
validation the CLI's `validate` verb runs and refuses on any error; warnings do
not block. This is the load-time red/green promise (design §1) applied at the
one moment it matters most — the moment a record starts being served to people
who did not write it.

### 2.2 Rollback

Rewrites `current` alone. Nothing is deleted, nothing is copied; the snapshot
being rolled back *to* is already on disk and the one being rolled back *from*
stays there. Audited.

### 2.3 The published data a rollback leaves behind — the phase's real ruling

Rolling `current` back to an older record leaves the published data directory
holding whatever the *newer* record fetched. If the two records' datasets
agree, that is ordinary stale-but-coherent data. If they do not — a dataset
whose fetch SQL or profile changed between the versions — the file on disk is
the answer to a question the serving record is no longer asking.

**Ruling: keep the data, and make the mismatch impossible to be silent.** The
per-dataset state gains the hash of the (profile, sql) that produced what is on
disk. A dataset whose definition in the serving record does not match that hash
is **stale on arrival**: the status line says the definition changed and the
data predates it, and the scheduler treats it as due regardless of interval.
A `manual` dataset says the same thing and waits for a person, because a manual
dataset waiting for a person is the whole meaning of `manual`.

Discarding the data instead was the alternative and is worse twice over: it
turns a rollback — the operation you reach for when something is wrong — into
an outage while every dataset refetches, and it throws away data that is
usually still correct, since most publishes change a layout and not a query.

This also closes a hole GDASH-2 already had: editing a `manual` dataset's SQL
and never refreshing served old-shaped data indefinitely, with nothing on the
page saying so. The mechanism is the same one either way, which is why it is in
scope here rather than deferred.

### 2.4 Session pinning

Design §7: a viewer resolves `current` at session open and **pins** that
snapshot for the session; no one sees a half-updated dashboard and publish
never coordinates with live sessions.

Built as a per-dashboard, path-scoped **session cookie** (no `Max-Age`, so the
browser drops it when the browser closes) holding the snapshot leaf. The pin is
validated the way `publication` already validates the pointer: a legal snapshot
name, never a path, and it must exist — a pin naming a snapshot that is gone
falls back to `current` rather than failing.

What this does not buy, stated plainly: there is no identity yet (GDASH-4), so
the "session" is a browser, not a person. A viewer who clears cookies or opens
a second browser gets `current`. That is the correct behaviour for what a
cookie can know, and it is the whole of §7's requirement — the requirement is
that a *reading* session is coherent, not that a person is tracked.

### 2.5 The reload nudge is a notice, not a reload

Publish must not yank the page out from under a pinned viewer — that is the
thing pinning exists to prevent. So SSE carries `publish` as a distinct event
from `refresh`, and the page's response to it is a **banner**: a new version
has been published, reload to see it. The viewer decides when.

`refresh` keeps its current meaning and its current behaviour, because new data
under the same record is what a dashboard is for.

### 2.6 Diff

`gdash diff <name> [from] [to]` and an endpoint returning the two texts and a
unified line diff, defaulting to "the published version before this one, and
this one". Hand-rolled per V3: an LCS over lines, unified output with a small
context window. Refusals and edge cases (a snapshot that does not exist, one
argument, none) get golden messages like every other refusal.

Design §7 calls this a headline feature for free — "what changed between the
numbers the CFO saw Tuesday and today". Free is doing some work in that
sentence, but only some: the *records* are text and diffable because of the
format ruling, which is what §7 means.

### 2.7 Audit

`publish`, `rollback`, and a refused publish with the reason, in the JSONL log
GDASH-2 built. No record contents in the log — a snapshot number and a
dashboard name, since the snapshot itself is on disk to be read.

## 3. Construction rules

Unchanged from GDASH-0 §4, GDASH-1 §3 and GDASH-2 §3, and additionally:

- **`e2e_publish.py` is deleted, not left beside the real thing.** It exists
  because publish did not; two ways to publish is exactly the duplication
  GDASH-1 removed for money formatting.
- **The publish path writes nothing the read path does not already
  understand.** GDASH-2's `publication` is the contract; if publish needs to
  write something it cannot read back, the contract is wrong and that is a
  finding, not a second reader.
- **F6 stands.** Every new public name is checked; the namespace sweep covers
  the new modules from their first commit, and this time it exists (G2-8).

## 4. Tests

Tests first, hermetic, scratch-clean, as before. Additionally:

- **Numbering under adversity**: publishing over a gap, over a non-numeric
  file in `snapshots/`, and over an empty directory.
- **A publish/rollback/publish sequence** asserting `current` moves and no
  snapshot is ever mutated or removed.
- **An invalid draft is refused publication**, with its golden message, and
  `current` is byte-identical afterwards.
- **The definition-change staleness rule** (§2.3): change a dataset's SQL,
  publish, and assert the page says the definition changed and the scheduler
  treats the dataset as due — including for a `manual` dataset, which must say
  so and *not* refresh itself.
- **Pin behaviour**: a pinned viewer keeps the old record across a publish; an
  unpinned one gets the new one; a pin naming a vanished snapshot falls back.
- **Diff goldens**, including an added line, a removed line, a changed line,
  and two identical snapshots.
- The end-to-end run publishes for real, rolls back, and asserts the banner
  arrives over SSE without the page reloading itself.

## 5. Done means

1. Publish, rollback and snapshot numbering work through the CLI, with an
   invalid draft refused.
2. A pinned viewer is not moved by a publish; an unpinned one is.
3. The reload nudge arrives as a notice, distinct from a data refresh.
4. Data whose defining query no longer matches the serving record says so on
   the page and is treated as due.
5. `gdash diff` returns a unified diff between two snapshots, with no
   dependency on an external binary.
6. `tests/e2e_publish.py` is gone, replaced by the real publish path.
7. The hermetic suite and the live-Postgres runner both pass; findings
   recorded; DONE note names everything deliberately not built.

## 6. Deliberately not built

Identity, sessions, login, CSRF, `user_*` (GDASH-4/5) — the pin is a cookie and
knows about a browser, not a person. Snapshot retention or pruning: all
snapshots are kept, per design §7. A designer UI (design §10); authoring is
still file editing. Diff rendering beyond unified text — no side-by-side, no
semantic diff of the JSON structure. Per-dataset publish. Scheduled or delayed
publish. Any notion of "unpublish" beyond rolling back to an earlier snapshot.

---

## 7. DONE note

All seven §5 criteria met. The hermetic suite is 17 suites — 388 in-process
assertions plus 94 end-to-end — green from a clean checkout with no services
running, ending scratch-clean; the opt-in live-Postgres runner passes 8/8.

**Built:** publish (draft bytes → `snapshots/NNNN.json` → atomic `current`
repoint), with an invalid draft refused and audited; rollback by name or one
step back; `snapshots` and `diff` verbs and a `/d/{name}/diff` endpoint;
session pinning as a path-scoped session cookie resolved through the same
containment as the pointer; the publish notice as an SSE event distinct from
`refresh`, answered by a banner rather than a reload; the definition-hash
staleness rule of §2.3; and a hand-rolled unified diff with no dependency on
`diff(1)`.

`tests/e2e_publish.py` is gone. The end-to-end run publishes through the real
path, and its remaining helper writes drafts only — which is what an author
does, since authoring is file editing.

**Fixed along the way, and it was GDASH-2's:** a published dashboard whose
dataset is `manual` could be refreshed from the browser and by nothing else
(G3-2). `refresh` now targets what the dashboard serves.

**Deliberately not built** — §6 stands, with these to record:

- **The pin knows a browser, not a person.** Clearing cookies or opening a
  second browser gets `current`. That is the whole of what a cookie can know
  and the whole of what §7 asks; identity is GDASH-4's.
- **The diff is unified text and nothing else.** No side-by-side, no
  structural diff of the JSON, no rendering in the page — the endpoint returns
  both texts so a caller can do better if it wants to.
- **A rewritten record is reported as a rewrite.** Beyond 250,000 LCS cells the
  diff stops trying to align lines and emits the old wholesale followed by the
  new. A record that large has not been edited.
- **Nothing prunes snapshots.** Design §7 says keep them all and they are small
  text; a retention policy is an operations question nobody has asked yet.
- **Publish is per-dashboard and immediate.** No scheduled publish, no
  publishing a group of dashboards together, no "unpublish" beyond rolling
  back to an earlier snapshot.

**Design edits still owed** (the maintainer's): §4's money headroom figure;
§4's render path, now bounded by the money type's storage scale; and §2's
content-hash sentence, which should say which dedupe is meant (G2-10).
