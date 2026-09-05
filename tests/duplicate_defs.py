#!/usr/bin/env python3
"""Refuse two definitions of one function name inside a single .bas file.

gBASIC accepts a library that defines the same function twice and silently
lets the LAST one win -- no error, no warning, and `library_collisions()` does
not see it, because that reports a name shared across DIFFERENT libraries
(finding G6-11).

This cost real time in GDASH-6: a mechanical rename rewrote a function's
DEFINITION as well as its call sites, leaving two `bind_as` in
gdash_auth_ldap.bas. The stale one shadowed the new one, so every bind went to
the live `ldap` module instead of the seam -- which looked exactly like a
broken test double.

Three greps would have found it. Now they run every time.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEF = re.compile(r"^\s*function\s+([A-Za-z_]\w*)\s*\(")

def main() -> int:
    bad = 0
    for path in sorted(list((ROOT / "src").glob("*.bas")) + list((ROOT / "tests").glob("*.bas"))):
        seen: dict[str, int] = {}
        for n, line in enumerate(path.read_text().splitlines(), 1):
            m = DEF.match(line)
            if not m:
                continue
            name = m.group(1)
            if name in seen:
                rel = path.relative_to(ROOT)
                print(f"{rel}:{n}: '{name}' is already defined at line {seen[name]}; "
                      f"gBASIC keeps the later one and says nothing", file=sys.stderr)
                bad += 1
            else:
                seen[name] = n
    if bad:
        print(f"{bad} duplicate function definition(s)", file=sys.stderr)
        return 1
    print("no function is defined twice in one file")
    return 0

if __name__ == "__main__":
    sys.exit(main())
