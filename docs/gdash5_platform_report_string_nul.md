# For the gbasic session — `replace` silently truncates at NUL

Found in gdash while writing LDAP filter and DN escaping, which is the worst
possible place to find it: RFC 4515 and RFC 4514 both require NUL to be
escaped, and the naive implementation eats it instead.

## What happens

```basic
print(len("a" + chr(0) + "b"))                       ' 3   -- correct
print(len(replace("a" + chr(0) + "b", "a", "A")))    ' 1   -- WRONG, no error
print(len(trim("a" + chr(0) + "b")))                 ' 1   -- WRONG, no error

r = replace(s, chr(0), "\00")   ' raises: replace: search string cannot be empty
p = split(s, chr(0))            ' raises: split separator cannot be empty
```

`len`, `mid`, `code` and `upper` are binary-safe. `replace` and `trim` are not:
they read the haystack as a C string and stop at the first NUL, returning a
shorter value with no error and no warning. And a `chr(0)` **needle** is
treated as the empty string and refused, so the obvious workaround is also
unavailable.

The reference is explicit that this should work, and in stronger terms than
the behaviour survives:

> A gBASIC string is a **binary-safe sequence of bytes**, UTF-8 by convention.
> It carries an explicit length, so any byte — including NUL (`chr(0)`) — is
> valid content; strings are not NUL-terminated from the program's point of
> view.

That is why this is filed as a defect rather than as a documentation gap.

## The sweep

`s = "a" + chr(0) + "b"`, so every correct answer is 3 (or the obvious
boolean). Run on `bcd0258`:

| builtin | result | |
|---|---|---|
| `len` | 3 | safe |
| `mid` | 3 | safe |
| `upper` / `lower` | 3 | safe |
| `reverse` | 3 | safe |
| `+` (concatenation) | 3 | safe |
| `string()` | 3 | safe |
| `code` | works | safe |
| `contains(s, "b")` | `true` | safe |
| `starts_with(s, "a")` | `true` | safe |
| `hex_encode` | `610062` | safe |
| `encode` | 10 chars, `\u0000` inside | safe |
| **`replace(s, "a", "a")`** | **1** | truncates, no error |
| **`trim`** | **1** | truncates, no error |
| **`join([s], "")`** | **1** | truncates, no error |
| **`split(s, "a")[1]`** | **0** (expected 2) | truncates, no error |
| **`ends_with(s, "b")`** | **`false`** | wrong answer, no error |
| `replace(s, chr(0), x)` | raises | needle treated as empty |
| `split(s, chr(0))` | raises | separator treated as empty |

The split is not along any line a caller could guess. **`contains` is
binary-safe and `ends_with` is not**, so two functions in the same family
disagree about what the string is — and `ends_with` does not truncate a value,
it returns the wrong boolean, which is the quietest failure on the list.

## Why it matters more than it looks

The failure mode is the dangerous one. It is not a raise a caller can guard; it
is a **shorter, plausible value**. Code that escapes untrusted text for a
protocol will silently drop the byte it was most obliged to handle, and the
result still looks like a valid escaped string.

In gdash the affected paths are the LDAP escapes, where a username reaches a
search filter and a DN. Both are now single hand-written scans over
`mid`/`code`, with a NUL round-trip asserted in the hermetic suite. That is the
right implementation for other reasons too — one pass means an escape
introduced by one rule is never re-escaped by the next — so gdash is not
blocked and needs nothing changed on its account.

## What would help

1. **Make `replace` and `trim` length-aware**, like `len`/`mid`/`code` already
   are. This is the actual fix.
2. **Allow a `chr(0)` needle** in `replace`, `split` and `contains`, or say in
   the reference that they are byte-string operations with C semantics —
   whichever is true. What should not stand is `len` and `mid` being
   length-aware while `replace` and `trim` are not, with nothing saying so:
   that makes binary-safety a per-function fact a caller has to discover one
   probe at a time.
3. If the C semantics are deliberate for performance, **raise on a haystack
   containing NUL** rather than truncating. An error a caller can see is worth
   far more here than a fast wrong answer.

The sweep above is what turned one finding into five: `trim` was tried on a
hunch after `replace`, and `join`, `split` and `ends_with` came out of running
the rest of the family rather than guessing which ones mattered.

## Reproducing

```basic
program main(args)
    s = "a" + chr(0) + "b"
    print("len:      " + string(len(s)))
    print("replace:  " + string(len(replace(s, "a", "A"))))
    print("trim:     " + string(len(trim(s))))
    print("mid:      " + string(len(mid(s, 0, 3))))
    print("upper:    " + string(len(upper(s))))
end program
```

Expected: `3 3 3 3 3`. Observed on `bcd0258`: `3 1 1 3 3`.
