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
    load gdash_channels from "gdash_channels.bas"
    load gdash_store from "gdash_store.bas"
    load gdash_sched from "gdash_sched.bas"
    load gdash_limits from "gdash_limits.bas"

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
    ' --- carrying the draft's data across (G11-11, ruled 2026-11-08) -----------
    '
    ' A published dashboard used to be empty until something refreshed it,
    ' because publish copied the record and nothing else. It now carries the
    ' draft's data -- per dataset, and not blindly, because a draft refreshes
    ' only when someone asks while a published dataset may refresh every few
    ' minutes, and republishing a title must not swap fresh data for stale:
    '
    '   published has none                     -> carry the draft's
    '   the definition changed                 -> carry the draft's, which was
    '                                             fetched under the new one
    '   unchanged, both have data              -> keep the more recent
    '   changed, and the draft never fetched
    '   it under the new definition            -> REFUSE, by name: old data
    '                                             under a new definition is the
    '                                             wrong answer to a new question
    '
    ' "Definition" is gdash_sched.definition_of: profile, SQL and declared
    ' columns, as recorded with the data when it was fetched.
    function data_plan(p, name, rec)
        carry = []
        keep = []
        empty = []
        refuse = []
        ddb = gdash_paths.stage_db(p, name, "draft")
        pdb = gdash_paths.stage_db(p, name, "published")
        for each dn in sort(keys(rec["datasets"]))
            ds = rec["datasets"][dn]
            want = gdash_sched.definition_of(ds)
            dst = gdash_sched.read_state(gdash_paths.dataset_state(p, name, "draft", dn))
            pst = gdash_sched.read_state(gdash_paths.dataset_state(p, name, "published", dn))
            draft_ok = gdash_store.has_dataset(ddb, dn) and dst.definition = want
            pub_has = gdash_store.has_dataset(pdb, dn)
            if not pub_has then
                if draft_ok then
                    carry = append(carry, dn)
                else
                    empty = append(empty, dn)
                end if
            else if pst.definition != want then
                if draft_ok then
                    carry = append(carry, dn)
                else
                    refuse = append(refuse, "dataset '" + dn + "' has a new definition and the draft has not fetched it under that definition; refresh the draft first (gdash refresh " + name + " --draft)")
                end if
            else if draft_ok and dst.last_success > pst.last_success then
                carry = append(carry, dn)
            else
                keep = append(keep, dn)
            end if
        next
        return { carry: carry, keep: keep, empty: empty, refuse: refuse }
    end function

    ' One dataset's draft data and its state into the published side, under
    ' the published dataset's own lock -- the one a refresh takes -- so a
    ' scheduler refresh and a publish never write it at once.
    function _carry(p, name, dn)
        made = gdash_paths.ensure_dir(gdash_paths.data_dir(p, name, "published"))
        lockpath = gdash_paths.dataset_lock(p, name, "published", dn)
        on error goto next
        lf {file} = lockpath
        if not gdash_paths.path_exists(lockpath) then
            write(lf, "")
        end if
        if error then
            return { ok: false, rows: 0, message: "cannot create the lock " + lockpath }
        end if
        on error stop
        got = { ok: false, rows: 0, message: "could not take the dataset lock" }
        with lock(lf)
            got = gdash_store.copy_dataset(gdash_paths.stage_db(p, name, "draft"), gdash_paths.stage_db(p, name, "published"), dn)
            if got.ok then
                st = gdash_sched.read_state(gdash_paths.dataset_state(p, name, "draft", dn))
                carried = { format: 1, last_attempt: st.last_attempt, last_success: st.last_success, last_error: "", rows: st.rows, hash: st.hash, requested: 0, definition: st.definition }
                wrote = gdash_sched.write_state(gdash_paths.dataset_state(p, name, "published", dn), carried)
            end if
        end with
        return got
    end function

    function publish(p, name)
        draft = gdash_paths.record_file(p, name)
        loaded = gdash_record.load_file(draft)
        if not loaded.ok then
            ' A record that does not validate cannot be published. This is
            ' load-time red/green (design §1) applied at the one moment it
            ' matters most: when a record starts being served to people who
            ' did not write it.
            logged = gdash_audit.event(p, "publish.refused", { dashboard: name, reason: join(loaded.errors, "; ") })
            return { ok: false, snapshot: "", message: "draft does not validate; nothing was published", errors: loaded.errors, notes: [] }
        end if

        ' AND ITS VISUALS MUST MATCH THEIR QUERIES (GDASH-21). Checked against
        ' the DRAFT's staged data, which is what the author has been looking
        ' at. A visual whose dataset has not refreshed cannot be checked; that
        ' is said, not refused, because a first publish before any refresh is
        ' the documented first-run sequence.
        chk = gdash_channels.check_channels(loaded.record, gdash_paths.stage_db(p, name, "draft"))
        notes = concat(chk.warnings, chk.unchecked)
        if count(chk.errors) > 0 then
            logged = gdash_audit.event(p, "publish.refused", { dashboard: name, reason: join(chk.errors, "; ") })
            return { ok: false, snapshot: "", message: "a visual names a column its query does not return; nothing was published", errors: chk.errors, notes: notes }
        end if

        ' A TENANT MAY NOT PUBLISH TO THE WORLD unless the operator granted it
        ' (GDASH-16). The page refuses to serve such a record as open anyway;
        ' refusing the publish is what tells the author, rather than leaving
        ' them to discover that their "public" dashboard asks for a sign-in.
        lim = gdash_limits.for_root(p)
        if default(loaded.record["access"], "") = "open" and not lim.open_access then
            why = "this site may not publish a dashboard with access: open; name view_groups instead, or ask the operator to permit open access"
            logged = gdash_audit.event(p, "publish.refused", { dashboard: name, reason: why })
            return { ok: false, snapshot: "", message: why, errors: [why], notes: notes }
        end if

        dplan = data_plan(p, name, loaded.record)
        if count(dplan.refuse) > 0 then
            logged = gdash_audit.event(p, "publish.refused", { dashboard: name, reason: join(dplan.refuse, "; ") })
            return { ok: false, snapshot: "", message: "a dataset's data cannot be carried across; nothing was published", errors: dplan.refuse, notes: notes }
        end if

        ' Carrying data is writing it, so the quota applies as it does to a
        ' refresh. A publish that carries nothing -- a title, a colour -- is
        ' never refused for disk.
        if count(dplan.carry) > 0 then
            quota = gdash_limits.disk_check(p, lim)
            if not quota.ok then
                why = "carrying the draft's data would add to a site over its disk quota (" + gdash_limits.bytes_text(quota.used) + " of " + gdash_limits.shown("disk_bytes", lim.disk_bytes) + "); nothing was published"
                if quota.kind = "volume" then
                    why = "carrying the draft's data was refused: " + gdash_limits.volume_check(p, lim).why + "; nothing was published"
                end if
                logged = gdash_audit.event(p, "publish.refused", { dashboard: name, reason: why })
                return { ok: false, snapshot: "", message: why, errors: [why], notes: notes }
            end if
        end if

        made = gdash_paths.ensure_dir(gdash_paths.snapshot_dir(p, name))
        leaf = _next_leaf(p, name)
        dest = gdash_paths.snapshot_file(p, name, leaf)

        on error goto next
        df {file} = draft
        text = read(df)
        if error then
            return { ok: false, snapshot: "", message: "cannot read the draft", errors: [], notes: notes }
        end if
        ' Byte-for-byte, not re-encoded from the parsed record: a snapshot is
        ' the text that was reviewed, and the diff between two snapshots is
        ' only meaningful if neither has been silently reformatted.
        sf {file} = dest
        write(sf, text)
        if error then
            return { ok: false, snapshot: "", message: "cannot write snapshot " + leaf, errors: [], notes: notes }
        end if

        ' The data before the pointer: a viewer who opens the new snapshot the
        ' moment `current` moves finds the data it was published with.
        for each dn in dplan.carry
            c = _carry(p, name, dn)
            if not c.ok then
                return { ok: false, snapshot: "", message: "dataset '" + dn + "' could not be carried across: " + c.message + "; snapshot " + leaf + " was written but not made current", errors: [], notes: notes }
            end if
            notes = append(notes, "carried dataset '" + dn + "' from the draft (" + string(c.rows) + " rows)")
        next
        for each dn in dplan.keep
            notes = append(notes, "kept the published data for '" + dn + "', which is as recent as the draft's")
        next
        for each dn in dplan.empty
            notes = append(notes, "dataset '" + dn + "' has no data yet on either side; refresh it to fill it")
        next

        if not _repoint(p, name, leaf) then
            return { ok: false, snapshot: "", message: "snapshot " + leaf + " was written but `current` could not be repointed", errors: [], notes: notes }
        end if
        if count(dplan.carry) > 0 then
            ' Open published pages reload onto the carried data.
            vfile = gdash_paths.version_file(p, name, "published")
            v = gdash_store.bump_version(vfile, vfile + ".tmp")
        end if
        logged = gdash_audit.event(p, "publish", { dashboard: name, snapshot: leaf, carried: dplan.carry })
        return { ok: true, snapshot: leaf, message: "", errors: [], notes: notes }
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
