# For the gbasic session — a library can define one function twice, silently

## What happens

```basic
library x
    function f()
        return 1
    end function
    function f()
        return 2
    end function
end library

program main(args)
    load x from "x.bas"
    print(x.f())      ' 2
end program
```

No parse error, no load error, no warning on stderr, no call-time note. The
later definition replaces the earlier one and nothing says so.

`library_collisions()` does not cover this, and should not — it answers "which
name is defined by more than one library", which is a different question with
a legitimate answer. Within a single library there is no check at all.

## Why it is worth an error rather than a warning

There is no legitimate reason to define the same function name twice in one
library. It is always one of: a bad merge, a copy-paste, or a mechanical rename
that matched more than it meant to. All three are bugs, and all three are
silent today.

The failure mode is the bad one. The program keeps running and does something
plausible, with whichever definition happened to be later in the file. Nothing
in the observable behaviour points at the duplicate — the symptom appears at
the call site, in a function that looks correct.

## How it was found

While putting a seam under gdash's LDAP client, call sites of
`bind_as(cfg, dn, password)` were rewritten mechanically. The definition line

```basic
    function bind_as(cfg, dn, password)
```

contains that same text, so the rename created a second definition rather than
updating the first. The stale one was later in the file and won, sending every
bind to the live `ldap` module instead of the injected test double.

The symptom: a test double that returned `{ ok: true }` when called directly,
and `unreachable` when called one frame away. That reads as a broken double, a
broken seam, or a broken record-of-functions call — three wrong places to look,
and the fourth was three greps away.

## What would help

1. **Error on a duplicate function definition within one library**, naming both
   line numbers. This is the fix.
2. If an error is too strong for compatibility, a **warning on stderr** at parse
   time, in the same channel as the built-in-shadowing note.
3. Either way, the message should name the *earlier* line as well as the later
   one; "already defined at line N" is what makes it a five-second fix.

gdash is not blocked — `tests/duplicate_defs.py` greps for it and runs in the
default suite — but a lint in one consumer's test directory is a poor substitute
for the parser refusing something that is never correct.
