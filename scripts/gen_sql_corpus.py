#!/usr/bin/env python3
"""Regenerate docs/gdash_sql_corpus.json: the SQL gdash actually runs.

G-SQL's dialect choices are to be measured over a corpus that includes
gdash's dataset, visual and ask SQL (gbasic docs/gsql_design.md §4.0). This
collects it from where it lives, so the corpus cannot drift from the code:

  - dataset and visual SQL from the reference records in dashboards/;
  - the statements gdash_store issues itself, as templates read from the
    gsql.exec/gsql.query calls (identifiers quoted by _quote_ident show as
    "<expr>", other spliced text as <expr>);
  - ask SQL from the canned model replies the suite uses. These are written
    by hand to stand in for a model, so they show the shape gdash accepts,
    not what a model produces.

Test placeholders ("select 1", "select a from d1") are deliberately left out:
they pin validator behaviour, not the SQL anyone writes.

    scripts/gen_sql_corpus.py           # rewrite the corpus
    scripts/gen_sql_corpus.py --check   # exit 1 if it is stale
"""
import sys, json, re, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/gdash_sql_corpus.json"
STORE = ROOT / "src/gdash_store.bas"

NOTES = [
    "runs_on 'source' is sent to the customer's database (PostgreSQL, ODBC) by a refresh; "
    "it never runs on the staging store. runs_on 'store' runs on G-SQL (since GDASH-20).",
    "Visual and ask SQL bind :name params; gdash rewrites them to positional $1, $2, ... before running (gdash_sql.bas).",
    "Every dataset of a dashboard is a table in that dashboard's one G-SQL database, named bare (orders); "
    "every read runs inside begin(\"read\").",
    "Money columns are money(<currency>), stored exactly; a plain number compared to one is an amount in that "
    "currency (amount > 1000 means USD 1000).",
]


# What the opaque parts of a store template stand for, keyed by the
# placeholder or keyword that makes a note necessary.
STORE_NOTES = {
    "<defs>": "<defs> is '\"<column>\" money(<currency>)|integer|number|string' per column (store_column_types).",
    "<sql>": "<sql> is ask or visual SQL, run inside begin(\"read\") so the engine refuses any write.",
    "alter table": "The swap: drop the live table and rename the staging one, with its _gdash_meta rows, in one transaction.",
}


def rel(p):
    return str(p.relative_to(ROOT))


def norm(sql):
    return " ".join(sql.split())


def from_records():
    out = []
    for f in sorted((ROOT / "dashboards").glob("*/*.json")):
        rec = json.loads(f.read_text())
        dash = rec.get("name", f.parent.name)
        for name, ds in rec.get("datasets", {}).items():
            e = {"id": f"{dash}.dataset.{name}", "kind": "dataset", "runs_on": "source",
                 "origin": "reference record", "where": rel(f), "sql": norm(ds["sql"])}
            money = {c: v["scale"] for c, v in ds.get("columns", {}).items() if v.get("type") == "money"}
            if money:
                e["money_scales"] = money
            out.append(e)
        for name, v in rec.get("visuals", {}).items():
            if "sql" in v:
                out.append({"id": f"{dash}.visual.{name}", "kind": "visual", "runs_on": "store",
                            "origin": "reference record", "where": rel(f), "sql": norm(v["sql"])})
    return out


def _args(text, start):
    """Split the call's argument list beginning at text[start] (just past '(')."""
    args, depth, cur, i, n = [], 0, "", start, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = text.index('"', i + 1)
            cur += text[i:j + 1]
            i = j + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                args.append(cur.strip())
                return args
            depth -= 1
        elif c == "," and depth == 0:
            args.append(cur.strip())
            cur = ""
            i += 1
            continue
        cur += c
        i += 1
    raise ValueError("unbalanced call: " + text[start:start + 80])


def _split_plus(expr):
    parts, depth, cur, i = [], 0, "", 0
    while i < len(expr):
        c = expr[i]
        if c == '"':
            j = expr.index('"', i + 1)
            cur += expr[i:j + 1]
            i = j + 1
            continue
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "+" and depth == 0:
            parts.append(cur.strip())
            cur = ""
            i += 1
            continue
        cur += c
        i += 1
    parts.append(cur.strip())
    return parts


def render(expr):
    out = ""
    for p in _split_plus(expr):
        if p.startswith('"') and p.endswith('"'):
            out += p[1:-1]
            continue
        m = re.fullmatch(r"_quote_ident\((.*)\)", p)
        if m:
            out += '"<' + m.group(1) + '>"'
            continue
        m = re.fullmatch(r"(?:join|string)\((\w[\w.\[\]]*).*\)", p)
        out += "<" + (m.group(1) if m else p) + ">"
    return out


def from_store():
    lines = STORE.read_text().splitlines()
    out, seen, func = [], set(), "?"
    for ln, line in enumerate(lines, 1):
        m = re.match(r"\s*function (\w+)", line)
        if m:
            func = m.group(1)
        m = re.search(r"gsql\.(exec|query)\(", line)
        if not m:
            continue
        args = _args(line, m.end())
        expr = args[1]
        if re.fullmatch(r"\w+", expr):
            # A statement built earlier in the same function: use the
            # nearest assignment above the call.
            for back in range(ln - 2, -1, -1):
                a = re.match(r"\s*" + expr + r"\s*=\s*(.*)$", lines[back])
                if a:
                    expr = a.group(1)
                    break
                if re.match(r"\s*function ", lines[back]):
                    break
        sql = render(expr)
        if sql in seen:
            continue
        seen.add(sql)
        out.append({"id": f"store.{func}.{len([e for e in out if e['id'].startswith('store.' + func + '.')]) + 1}",
                    "kind": "store internal", "runs_on": "store", "origin": "code template",
                    "where": f"{rel(STORE)}:{ln}", "sql": sql,
                    "binds": len(args) > 2})
        notes = [v for k, v in STORE_NOTES.items() if k in sql]
        if notes:
            out[-1]["note"] = " ".join(notes)
    return out


def from_canned_ask():
    out, seen = [], set()
    for f in sorted((ROOT / "tests").glob("*.sh")):
        text = f.read_text()
        for m in re.finditer(r'"content":\[\{"type":"text","text":"((?:[^"\\]|\\.)*)"', text):
            sql = norm(json.loads('"' + m.group(1) + '"'))
            if sql in seen:
                continue
            seen.add(sql)
            ln = text.count("\n", 0, m.start()) + 1
            out.append({"id": f"ask.canned.{len(out) + 1}", "kind": "ask", "runs_on": "store",
                        "origin": "canned model reply (hand-written)", "where": f"{rel(f)}:{ln}", "sql": sql})
    return out


def build():
    corpus = {
        "about": "The SQL gdash runs, for G-SQL's dialect measurements. Generated by scripts/gen_sql_corpus.py; do not edit.",
        "notes": NOTES,
        "store_column_types": {"money": "money(<currency>), exact; display scale in _gdash_meta", "integer": "integer",
                               "real": "number", "text and anything undeclared": "string"},
        "statements": from_records() + from_store() + from_canned_ask(),
    }
    return json.dumps(corpus, indent=2) + "\n"


def main() -> int:
    want = build()
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != want:
            print("SQL corpus is stale; run scripts/gen_sql_corpus.py", file=sys.stderr)
            return 1
        print("SQL corpus matches the sources")
        return 0
    OUT.write_text(want)
    print("regenerated", OUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
