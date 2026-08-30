' Publish, rollback, and snapshot numbering (design §7).

program main(args)
    load gdash_test from "gdash_test.bas"
    load gdash_paths from "../src/gdash_paths.bas"
    load gdash_publish from "../src/gdash_publish.bas"

    s = gdash_test.suite("publish")
    root = args[0]
    p = gdash_paths.roles(root)

    ' A dashboard whose draft is the reference record.
    made = gdash_paths.ensure_dir(gdash_paths.dashboard_dir(p, "sales"))
    src {file} = "dashboards/sales/draft.json"
    text = read(src)
    df {file} = gdash_paths.record_file(p, "sales")
    write(df, text)

    ' --- before any publish ---
    s = gdash_test.eq(s, count(gdash_publish.snapshots(p, "sales")), 0, "a fresh dashboard has no snapshots")
    s = gdash_test.eq(s, gdash_paths.publication(p, "sales").mode, "draft", "and serves its draft")

    ' --- publish ---
    r1 = gdash_publish.publish(p, "sales")
    s = gdash_test.ok(s, r1.ok, "publish succeeds -- " + r1.message)
    s = gdash_test.eq(s, r1.snapshot, "0001.json", "numbering starts at 0001")
    pub = gdash_paths.publication(p, "sales")
    s = gdash_test.eq(s, pub.mode, "published", "the dashboard is now published")
    s = gdash_test.eq(s, pub.snapshot, "0001.json", "and names its snapshot")

    ' The snapshot is the draft's BYTES, not a re-encoding: a diff between two
    ' snapshots is only meaningful if neither was silently reformatted.
    sf {file} = gdash_paths.snapshot_file(p, "sales", "0001.json")
    s = gdash_test.eq(s, read(sf), text, "the snapshot is byte-identical to the draft")

    ' --- editing the draft does not disturb what is published ---
    write(df, replace(text, chr(34) + "Sales" + chr(34), chr(34) + "Sales (edited)" + chr(34)))
    s = gdash_test.eq(s, read(sf), text, "a draft edit cannot reach a published snapshot")
    s = gdash_test.eq(s, gdash_paths.publication(p, "sales").snapshot, "0001.json", "and does not move `current`")

    ' --- second publish ---
    r2 = gdash_publish.publish(p, "sales")
    s = gdash_test.eq(s, r2.snapshot, "0002.json", "the second publish numbers 0002")
    s = gdash_test.eq(s, count(gdash_publish.snapshots(p, "sales")), 2, "both snapshots are kept")
    s = gdash_test.contains_text(s, string(gdash_publish.snapshot_text(p, "sales", "0002.json")), "Sales (edited)", "the second snapshot carries the edit")
    s = gdash_test.contains_text(s, string(gdash_publish.snapshot_text(p, "sales", "0001.json")), chr(34) + "Sales" + chr(34), "and the first still does not")

    ' --- rollback ---
    b1 = gdash_publish.rollback(p, "sales", "")
    s = gdash_test.ok(s, b1.ok, "rollback with no target steps back one -- " + b1.message)
    s = gdash_test.eq(s, b1.snapshot, "0001.json", "to the previous snapshot")
    s = gdash_test.eq(s, gdash_paths.publication(p, "sales").snapshot, "0001.json", "and `current` says so")
    s = gdash_test.eq(s, count(gdash_publish.snapshots(p, "sales")), 2, "rollback deletes nothing")

    ' Rolling back past the earliest is refused, not wrapped.
    b2 = gdash_publish.rollback(p, "sales", "")
    s = gdash_test.ok(s, not b2.ok, "rollback past the earliest snapshot is refused")
    s = gdash_test.contains_text(s, b2.message, "earliest snapshot", "and says why")

    ' Rolling forward by naming a target is the same operation.
    b3 = gdash_publish.rollback(p, "sales", "0002.json")
    s = gdash_test.ok(s, b3.ok, "a named target moves `current` to it")
    s = gdash_test.eq(s, gdash_paths.publication(p, "sales").snapshot, "0002.json", "including forward")

    s = gdash_test.ok(s, not gdash_publish.rollback(p, "sales", "9999.json").ok, "a snapshot that does not exist is refused")
    s = gdash_test.ok(s, not gdash_publish.rollback(p, "sales", "../../../etc/passwd").ok, "a target with a path separator is refused")

    ' --- an invalid draft cannot be published ---
    before_leaf = gdash_paths.read_pointer(p, "sales")
    write(df, "{ " + chr(34) + "format" + chr(34) + ": 1 }")
    bad = gdash_publish.publish(p, "sales")
    s = gdash_test.ok(s, not bad.ok, "an invalid draft is refused publication")
    s = gdash_test.contains_text(s, bad.message, "nothing was published", "and says nothing was published")
    s = gdash_test.ok(s, count(bad.errors) > 0, "with the validation errors")
    s = gdash_test.eq(s, gdash_paths.read_pointer(p, "sales"), before_leaf, "`current` did not move")
    s = gdash_test.eq(s, count(gdash_publish.snapshots(p, "sales")), 2, "and no snapshot was written")

    ' --- numbering survives an untidy directory ---
    write(df, text)
    stray {file} = gdash_paths.snapshot_file(p, "sales", "notes.txt")
    write(stray, "an operator left this here")
    gap {file} = gdash_paths.snapshot_file(p, "sales", "0009.json")
    write(gap, text)
    r3 = gdash_publish.publish(p, "sales")
    s = gdash_test.eq(s, r3.snapshot, "0010.json", "numbering continues past a gap, ignoring what is not a snapshot")
    s = gdash_test.eq(s, count(gdash_publish.snapshots(p, "sales")), 4, "the stray file is not counted as a snapshot")

    ' --- pinning (design §7) ---
    ' A pinned viewer keeps the snapshot they opened, whatever `current` does.
    pin = gdash_paths.pinned(p, "sales", "0001.json")
    s = gdash_test.eq(s, pin.snapshot, "0001.json", "a pin holds an older snapshot")
    s = gdash_test.eq(s, gdash_paths.publication(p, "sales").snapshot, "0010.json", "while `current` has moved on")

    ' A pin naming a snapshot that is gone falls back rather than failing: the
    ' viewer asked for a coherent read, not for that exact file.
    s = gdash_test.eq(s, gdash_paths.pinned(p, "sales", "8888.json").snapshot, "0010.json", "a vanished pin falls back to current")
    s = gdash_test.eq(s, gdash_paths.pinned(p, "sales", "../../etc/x").snapshot, "0010.json", "a pin with a path separator falls back too")
    s = gdash_test.eq(s, gdash_paths.pinned(p, "sales", "").snapshot, "0010.json", "an empty pin is just current")

    ' --- the log carries the lifecycle ---
    alf {file} = gdash_paths.audit_log(p)
    audit = read(alf)
    s = gdash_test.contains_text(s, audit, chr(34) + "publish" + chr(34), "publish is audited")
    s = gdash_test.contains_text(s, audit, "rollback", "so is rollback")
    s = gdash_test.contains_text(s, audit, "publish.refused", "so is a refused publish")

    exit(gdash_test.report(s))
end program
