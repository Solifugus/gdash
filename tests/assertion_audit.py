#!/usr/bin/env python3
"""Find end-to-end assertions that could pass with the feature removed.

`run_e2e.sh` asserts with `grep -F` against whole HTML pages. Three such
assertions have already produced a false result in this project, every one of
them because the needle also appears in the STYLESHEET or the SHIM -- markup
gdash emits on every page whatever rendered (finding G6-6).

Those three were caught only because they failed in the direction that shows.
The other direction is silent: a `has` matching page furniture passes forever
while testing nothing.

This reads the needles out of the suite and checks them against the furniture,
which is captured by rendering `_style()` and `_shim()` with no dashboard at
all. A needle found there is reported. It cannot prove an assertion is
meaningful; it can prove one is not.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
E2E = ROOT / "tests" / "run_e2e.sh"
GBASIC = pathlib.Path(subprocess.os.environ.get("GDASH_GBASIC", str(pathlib.Path.home() / "development/gbasic/gbasic")))

PROBE = '''program main(args)
    load gdash_app from "%s"
    print(gdash_app._style())
    print(gdash_app._shim())
end program
''' % (ROOT / "src" / "gdash_app.bas")

# has "$var" "needle" "label"   /   hasnt "$var" 'needle' "label"
CALL = re.compile(r'''^\s*(has|hasnt)\s+"[^"]*"\s+(?:"((?:[^"\\]|\\.)*)"|'([^']*)')\s+"([^"]*)"''')

def furniture() -> str:
    with tempfile.TemporaryDirectory() as d:
        probe = pathlib.Path(d) / "furniture.bas"
        probe.write_text(PROBE)
        out = subprocess.run([str(GBASIC), str(probe)], capture_output=True, text=True)
        return out.stdout

def main() -> int:
    if not GBASIC.exists():
        print(f"gbasic not found at {GBASIC}", file=sys.stderr)
        return 2
    static = furniture()
    if not static.strip():
        print("could not render the page furniture; the audit cannot run", file=sys.stderr)
        return 2

    hollow = []
    checked = 0
    for n, line in enumerate(E2E.read_text().splitlines(), 1):
        m = CALL.match(line)
        if not m:
            continue
        kind, dq, sq, label = m.group(1), m.group(2), m.group(3), m.group(4)
        needle = dq if dq is not None else sq
        if needle is None or "$" in needle:
            continue          # interpolated at runtime; not statically checkable
        checked += 1
        if needle and needle in static:
            hollow.append((n, kind, needle, label))

    for n, kind, needle, label in hollow:
        print(f"tests/run_e2e.sh:{n}: {kind} <{needle}> also matches page furniture "
              f"-- \"{label}\" can pass with the feature removed", file=sys.stderr)
    if hollow:
        print(f"{len(hollow)} of {checked} statically-checkable assertions match "
              f"the stylesheet or the shim", file=sys.stderr)
        return 1
    print(f"no end-to-end assertion matches page furniture ({checked} checked)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
