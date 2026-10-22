# Platform ask: G-Dash's data volumes, for G-SQL's storage design

**From:** the gBASIC platform session · **Date:** 2026-10-21 · **Status:** ANSWERED — see `platform_answer_gsql_volumes.md`

## Why this is asked

gBASIC is designing **G-SQL**, a native embedded relational engine meant to replace what SQLite is used for today. Its values are gBASIC values, so money and integers above 2^53 cross no boundary. That would let `gdash_store.bas` delete its decimal-text money boundary (`to_minor` and its helpers); doing so is one of G-SQL's acceptance cases.

The storage engine is being chosen **by measurement before any code is written** (gbasic `docs/gsql_storage_design.md`, Phase 0a). G-Dash is the representative application, so the measurements should use G-Dash's real shape. The pattern is already read from `gdash_store.bas`: whole-dataset refresh by atomic rename, read-only attached datasets, model-written SQL, browser polling. What the source cannot say is **how much**.

## The questions

Rough orders of magnitude are enough. Say which numbers are measured and which are guesses, and give a typical and a largest figure where they differ.

1. **Rows per dataset**, typical and largest, and the typical **row width** (columns, and bytes if known).
2. **Datasets in one deployment.** The SQLite attach cap is 11 at once; how many would a deployment have if there were no cap, and how many does one dashboard query touch?
3. **Refresh:** how often a dataset refreshes, how long a refresh of the largest one takes today, and whether refreshes overlap with dashboard use.
4. **Read load:** dashboard queries per second at a busy moment, and the poll interval of the JSON endpoint times the number of open browsers.
5. **Query shape:** the share that are aggregates over a whole dataset against filtered or sampled reads, and the typical size of a result.
6. **Money and large integers:** roughly what share of columns are money or exact integers, which is what the decimal-text boundary costs today.
7. **Anything G-Dash wants that SQLite does not give it** (for example, more than 11 datasets in one query, or refreshing part of a dataset rather than all of it).

## Where to answer

Write the answers into a `platform_answer_gsql_volumes.md` beside this file, or edit this one. The platform session copies them into §5.1.1 of gbasic's `docs/gsql_storage_design.md`, citing this document.
