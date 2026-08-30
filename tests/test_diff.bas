' The snapshot diff, pinned by golden. Hand-rolled per step-0 V3, so it is
' this suite -- not diff(1) -- that says whether it is right.

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_diff from "../src/gdash_diff.bas"

    s = gdash_test.suite("diff")
    nl = chr(10)

    ' --- lines ---
    s = gdash_test.eq(s, count(gdash_diff.text_lines("a" + nl + "b" + nl)), 2, "a trailing newline does not make a third line")
    s = gdash_test.eq(s, count(gdash_diff.text_lines("a" + nl + "b")), 2, "and its absence does not lose one")
    s = gdash_test.eq(s, count(gdash_diff.text_lines("")), 0, "empty text has no lines -- an empty record is not a record with a blank line")
    s = gdash_test.eq(s, count(gdash_diff.text_lines("a" + chr(13) + nl + "b" + nl)), 2, "CRLF is normalized")

    ' --- identical texts ---
    same = "one" + nl + "two" + nl + "three" + nl
    s = gdash_test.eq(s, gdash_diff.unified(same, same, "a", "b", 2), "", "identical texts diff to nothing at all")
    s = gdash_test.ok(s, not gdash_diff.changed(same, same), "and report unchanged")

    ' --- one changed line ---
    edited = "one" + nl + "TWO" + nl + "three" + nl
    d = gdash_diff.unified(same, edited, "0001.json", "0002.json", 1)
    s = gdash_test.ok(s, gdash_diff.changed(same, edited), "a changed line is a change")
    s = gdash_test.eq(s, d, "--- 0001.json" + nl + "+++ 0002.json" + nl + "@@ -1,3 +1,3 @@" + nl + " one" + nl + "-two" + nl + "+TWO" + nl + " three" + nl, "one changed line, with context")

    ' --- an added line ---
    added = "one" + nl + "two" + nl + "two and a half" + nl + "three" + nl
    s = gdash_test.eq(s, gdash_diff.unified(same, added, "a", "b", 1), "--- a" + nl + "+++ b" + nl + "@@ -2,2 +2,3 @@" + nl + " two" + nl + "+two and a half" + nl + " three" + nl, "an added line")

    ' --- a removed line ---
    s = gdash_test.eq(s, gdash_diff.unified(added, same, "a", "b", 1), "--- a" + nl + "+++ b" + nl + "@@ -2,3 +2,2 @@" + nl + " two" + nl + "-two and a half" + nl + " three" + nl, "a removed line is the same edit, reversed")

    ' --- two distant changes make two hunks ---
    long_a = "1" + nl + "2" + nl + "3" + nl + "4" + nl + "5" + nl + "6" + nl + "7" + nl + "8" + nl + "9" + nl
    long_b = "1x" + nl + "2" + nl + "3" + nl + "4" + nl + "5" + nl + "6" + nl + "7" + nl + "8" + nl + "9x" + nl
    two = gdash_diff.unified(long_a, long_b, "a", "b", 1)
    s = gdash_test.eq(s, count(split(two, "@@ -")) - 1, 2, "changes far apart make two hunks, not one with the middle in it")
    s = gdash_test.ok(s, not contains(two, " 5"), "and the untouched middle is not printed")

    ' A wider context window merges them again.
    s = gdash_test.eq(s, count(split(gdash_diff.unified(long_a, long_b, "a", "b", 6), "@@ -")) - 1, 1, "a wide enough context merges the hunks")

    ' --- everything replaced ---
    all_a = "a" + nl + "b" + nl
    all_b = "x" + nl + "y" + nl
    rep = gdash_diff.unified(all_a, all_b, "a", "b", 2)
    s = gdash_test.contains_text(s, rep, "-a", "a wholesale replacement removes the old")
    s = gdash_test.contains_text(s, rep, "+y", "and adds the new")

    ' --- from and to nothing ---
    s = gdash_test.contains_text(s, gdash_diff.unified("", "new" + nl, "a", "b", 2), "+new", "adding to an empty record")
    s = gdash_test.contains_text(s, gdash_diff.unified("old" + nl, "", "a", "b", 2), "-old", "emptying a record")

    ' --- a real record edit ---
    ' What a publish usually is: one line different in a hundred. The prefix
    ' and suffix trim means the LCS table is a few cells, not ten thousand.
    src {file} = "dashboards/sales/draft.json"
    rec_a = read(src)
    rec_b = replace(rec_a, chr(34) + "Sales" + chr(34), chr(34) + "Sales, revised" + chr(34))
    rd = gdash_diff.unified(rec_a, rec_b, "0001.json", "0002.json", 3)
    s = gdash_test.eq(s, count(split(rd, "@@ -")) - 1, 1, "a one-line record edit is one hunk")
    s = gdash_test.contains_text(s, rd, "+  " + chr(34) + "title" + chr(34) + ": " + chr(34) + "Sales, revised" + chr(34) + ",", "showing the new line")
    s = gdash_test.contains_text(s, rd, "-  " + chr(34) + "title" + chr(34) + ": " + chr(34) + "Sales" + chr(34) + ",", "and the old one")
    s = gdash_test.ok(s, count(gdash_diff.text_lines(rd)) < 12, "and nothing else -- " + string(count(gdash_diff.text_lines(rd))) + " lines")

    exit(gdash_test.report(s))
end program
