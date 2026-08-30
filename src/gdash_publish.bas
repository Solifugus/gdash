' gdash — publish, rollback, snapshots.
'
' Design §7: immutable published snapshots plus one mutable draft. Editing
' touches draft.json only; publish copies it to snapshots/NNNN.json and
' atomically repoints `current`; rollback rewrites `current` alone.
'
' Nothing here deletes or mutates a snapshot. Snapshots are small text and the
' design says to keep them all -- which is also what makes rollback free and
' the version diff possible at all.
'
' `current` is a regular file naming a snapshot, not a symlink: the
' interpreter resolves symlinks but creates none (GDASH-3 step-0 V1). The
' repoint is one atomic_replace, the same single rename(2) that swaps a
' dataset.

library gdash_publish

    load gdash_paths from "gdash_paths.bas"
    load gdash_record from "gdash_record.bas"
    load gdash_audit from "gdash_audit.bas"

    function _pad4(n)
        s = string(n)
        while len(s) < 4
            s = "0" + s
        end while
        return s
    end function

    function _leaf_number(leaf)
        if not ends_with(leaf, ".json") then
            return -1
        end if
        stem = mid(leaf, 0, len(leaf) - 5)
        if stem = "" then
            return -1
        end if
        i = 0
        while i < len(stem)
            if not contains("0123456789", mid(stem, i, 1)) then
                return -1
            end if
            i += 1
        end while
        return number(stem)
    end function

    ' Every snapshot leaf, oldest first. Anything in the directory that is not
    ' NNNN.json is ignored rather than refused: an operator's stray copy of a
    ' record should not stop a publish, and it cannot be mistaken for a
    ' snapshot because the numbering never produces that name.
    function snapshots(p, name)
        dir = gdash_paths.snapshot_dir(p, name)
        found = []
        on error goto next
        entries = files(dir)
        if error then
            return found
        end if
        i = 0
        while i < count(entries)
            if _leaf_number(entries[i].name) >= 0 then
                found = concat(found, [entries[i].name])
            end if
            i += 1
        end while
        return sort(found)
    end function

    function _next_leaf(p, name)
        have = snapshots(p, name)
        highest = 0
        i = 0
        while i < count(have)
            n = _leaf_number(have[i])
            if n > highest then
                highest = n
            end if
            i += 1
        end while
        return _pad4(highest + 1) + ".json"
    end function

    function _repoint(p, name, leaf)
        ptr = gdash_paths.current_pointer(p, name)
        tmp = ptr + ".tmp"
        on error goto next
        tf {file} = tmp
        write(tf, leaf + chr(10))
        if error then
            return false
        end if
        atomic_replace(tmp, ptr)
        if error then
            return false
        end if
        return true
    end function

    ' Returns { ok, snapshot, message, errors }.
    function publish(p, name)
        draft = gdash_paths.record_file(p, name)
        loaded = gdash_record.load_file(draft)
        if not loaded.ok then
            ' A record that does not validate cannot be published. This is
            ' load-time red/green (design §1) applied at the one moment it
            ' matters most: when a record starts being served to people who
            ' did not write it.
            logged = gdash_audit.event(p, "publish.refused", { dashboard: name, reason: join(loaded.errors, "; ") })
            return { ok: false, snapshot: "", message: "draft does not validate; nothing was published", errors: loaded.errors }
        end if

        made = gdash_paths.ensure_dir(gdash_paths.snapshot_dir(p, name))
        leaf = _next_leaf(p, name)
        dest = gdash_paths.snapshot_file(p, name, leaf)

        on error goto next
        df {file} = draft
        text = read(df)
        if error then
            return { ok: false, snapshot: "", message: "cannot read the draft", errors: [] }
        end if
        ' Byte-for-byte, not re-encoded from the parsed record: a snapshot is
        ' the text that was reviewed, and the diff between two snapshots is
        ' only meaningful if neither has been silently reformatted.
        sf {file} = dest
        write(sf, text)
        if error then
            return { ok: false, snapshot: "", message: "cannot write snapshot " + leaf, errors: [] }
        end if

        if not _repoint(p, name, leaf) then
            return { ok: false, snapshot: "", message: "snapshot " + leaf + " was written but `current` could not be repointed", errors: [] }
        end if
        logged = gdash_audit.event(p, "publish", { dashboard: name, snapshot: leaf })
        return { ok: true, snapshot: leaf, message: "", errors: [] }
    end function

    ' Rollback rewrites `current` alone: the snapshot being rolled back TO is
    ' already on disk, and the one being rolled back FROM stays there. With no
    ' target named, it steps back one from whatever is current.
    function rollback(p, name, leaf)
        have = snapshots(p, name)
        if count(have) = 0 then
            return { ok: false, snapshot: "", message: "dashboard '" + name + "' has no snapshots to roll back to", errors: [] }
        end if
        target = leaf
        if target = "" then
            now_leaf = gdash_paths.read_pointer(p, name)
            at = -1
            i = 0
            while i < count(have)
                if have[i] = now_leaf then
                    at = i
                end if
                i += 1
            end while
            if at <= 0 then
                return { ok: false, snapshot: "", message: "dashboard '" + name + "' is already at its earliest snapshot", errors: [] }
            end if
            target = have[at - 1]
        end if
        if gdash_paths.resolve_snapshot(p, name, target) = "" then
            return { ok: false, snapshot: "", message: "no such snapshot: " + target, errors: [] }
        end if
        if not _repoint(p, name, target) then
            return { ok: false, snapshot: "", message: "could not repoint `current`", errors: [] }
        end if
        logged = gdash_audit.event(p, "rollback", { dashboard: name, snapshot: target })
        return { ok: true, snapshot: target, message: "", errors: [] }
    end function

    function snapshot_text(p, name, leaf)
        path = gdash_paths.resolve_snapshot(p, name, leaf)
        if path = "" then
            return unknown
        end if
        on error goto next
        f {file} = path
        t = read(f)
        if error then
            return unknown
        end if
        return t
    end function

end library
