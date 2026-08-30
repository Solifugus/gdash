#!/usr/bin/env python3
"""Regenerate the format doc's refusal catalog from the golden file.

The catalog has one source -- tests/goldens/validation.golden -- and this
copies it into docs/gdash_record_format.md between the generated markers.
The suite checks the two agree, so drift fails a test rather than quietly
leaving the documentation wrong.

    scripts/gen_catalog_appendix.py           # rewrite the appendix
    scripts/gen_catalog_appendix.py --check   # exit 1 if it is stale
"""
import sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
GOLDEN = ROOT / "tests/goldens/validation.golden"
DOC = ROOT / "docs/gdash_record_format.md"
BEGIN = "<!-- BEGIN GENERATED CATALOG -->"
END = "<!-- END GENERATED CATALOG -->"

def build(doc: str, golden: str) -> str:
    a, b = doc.index(BEGIN), doc.index(END)
    return doc[:a] + BEGIN + "\n```\n" + golden.rstrip("\n") + "\n```\n" + doc[b:]

def main() -> int:
    doc, golden = DOC.read_text(), GOLDEN.read_text()
    want = build(doc, golden)
    if "--check" in sys.argv:
        if doc != want:
            print("format doc catalog is stale; run scripts/gen_catalog_appendix.py", file=sys.stderr)
            return 1
        print("format doc catalog matches the golden")
        return 0
    DOC.write_text(want)
    print("regenerated the catalog appendix in", DOC.relative_to(ROOT))
    return 0

if __name__ == "__main__":
    sys.exit(main())
