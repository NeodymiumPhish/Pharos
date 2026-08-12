import Foundation

// MARK: - TagMatcher

/// Maps the rows of a result to the tags that cover them.
///
/// Pure and offline-testable: no AppKit, no FFI, no store. `TagStore` supplies
/// the index and `ResultsGridVC` supplies the result; this type only decides.
///
/// Two tiers, chosen by the identity block:
///
///  - **Strong** — `candidates` is not empty. Each row carries a precomputed key
///    per candidate, built by the core. Matching is a dictionary lookup.
///  - **Weak** — `candidates` is empty. The row has no key, so the whole row is
///    compared as a fingerprint. See `matchWeak` for the three rules that keep it
///    trustworthy.
enum TagMatcher {

    /// The store's index key. The kind belongs in it: the SQLite unique index
    /// holds `(connection, table, kind, value)`, so a key without the kind would
    /// bring that collision back into memory — a `pk` string and a fingerprint
    /// string for two different rows could replace each other.
    ///
    /// The separator is a raw `\u{1}`, unlike `RowFingerprint`'s length-prefixed
    /// fields — safely, because a collision here needs a table key containing
    /// U+0001 followed by text equal to a valid kind, and this same function both
    /// builds and reads the index, so a collision could only ever cause a WRONG
    /// match, never a missed one. A fingerprint has no such luxury: it is stored
    /// and re-derived on a later query, so a length-prefix escape is load-bearing
    /// there in a way it is not here.
    static func compositeKey(tableKey: String, kind: String, value: String) -> String {
        "\(tableKey)\u{1}\(kind)\u{1}\(value)"
    }

    /// Build the store's index from a connection's tags.
    ///
    /// ONE ENTRY PER STORED KEY, not per tag. A strong tag carries both a `pk` and a
    /// `unique` key and therefore appears twice — that is what lets a tag made
    /// through one candidate be found again through the other.
    ///
    /// This lives on `TagMatcher` rather than on `TagStore` for two reasons. It is
    /// pure, so the offline harness can test it; and the matcher's own test fixtures
    /// call it instead of reimplementing it, so the tests and the app can never
    /// disagree about how the index is keyed.
    static func index(_ tags: [RowTag]) -> [String: RowTag] {
        var out: [String: RowTag] = [:]
        for tag in tags {
            for key in tag.keys {
                out[compositeKey(tableKey: tag.tableKey,
                                 kind: key.identityKind,
                                 value: key.identityValue)] = tag
            }
        }
        return out
    }

    /// Tags by index into `rows`.
    ///
    /// - Parameters:
    ///   - identity: the result's block, or nil when the result has no source table.
    ///   - columns: result column names, for the weak path only.
    ///   - rows: result values as text. The row COUNT comes from this, so the two
    ///     paths cannot disagree about how many rows exist; the weak path also
    ///     reads the values. The strong path reads the count only — its keys are
    ///     precomputed per row by the core.
    ///   - tagsByIdentity: the store's index.
    static func match(
        identity: RowIdentity?,
        columns: [String],
        rows: [[String?]],
        tagsByIdentity: [String: RowTag]
    ) -> [Int: RowTag] {
        // The common case: nothing is tagged. This is a smoke check, not a
        // measured fast path — it never fails on its own either way.
        guard !tagsByIdentity.isEmpty else { return [:] }
        guard let identity else { return [:] }

        if identity.candidates.isEmpty {
            return matchWeak(identity: identity, columns: columns, rows: rows,
                             tagsByIdentity: tagsByIdentity)
        }
        return matchStrong(identity: identity, rowCount: rows.count,
                           tagsByIdentity: tagsByIdentity)
    }

    /// Walk the rows once, trying each candidate strongest first.
    private static func matchStrong(
        identity: RowIdentity,
        rowCount: Int,
        tagsByIdentity: [String: RowTag]
    ) -> [Int: RowTag] {
        var out: [Int: RowTag] = [:]
        for row in 0..<rowCount {
            for candidate in identity.candidates {
                // A block shorter than the row count is a core bug. Degrade to
                // "no tag" rather than trapping on the index.
                guard row < candidate.keys.count else { continue }
                let key = candidate.keys[row]
                // The empty string is the core's "no identity" sentinel for a
                // NULL key value. It must never match, not even a stored empty
                // key — otherwise every keyless row takes the same tag.
                guard !key.isEmpty else { continue }
                let composite = compositeKey(tableKey: identity.tableKey,
                                             kind: candidate.kind,
                                             value: key)
                if let tag = tagsByIdentity[composite] {
                    out[row] = tag
                    break // strongest hit wins
                }
            }
        }
        return out
    }

    /// The grouping key for the fingerprint tier: a table plus a stored column set.
    ///
    /// The table MUST be part of it. Rule 1 admits every table in the result, and two
    /// tags on different tables can store the same column names with the same values
    /// — so they encode to the same fingerprint string. Keying the group on columns
    /// alone let one silently replace the other in the per-group key-to-tag map that
    /// `claims` builds, and rule 3 never saw the ambiguity because the two had
    /// already collapsed into one entry.
    ///
    /// `columns` is sorted by UTF-8 bytes with the same comparator
    /// `RowFingerprint.swift` uses for column names — so the two never disagree
    /// about column order — and this is what puts tags storing `["a","b"]` and
    /// `["b","a"]` into the SAME group. They encode to the same row string either
    /// way, since `RowFingerprint.encode` canonicalises internally, so keeping them
    /// in separate groups would run the encoder twice per row for nothing, which
    /// undercuts the reason for grouping at all. That same canonicalisation is also
    /// what makes it safe to hand this sorted order to the encoder directly: the
    /// row string still equals the stored string whatever order either side used.
    private struct FingerprintGroup: Hashable {
        let tableKey: String
        let columns: [String]
    }

    /// The fingerprint tier: the result carries no key, so the whole row is the
    /// identity.
    ///
    /// Three rules make this trustworthy, and all three are necessary:
    ///
    ///  1. The tag's table must appear in the result's `tableKeys`. Without this a
    ///     tag follows a value into an unrelated table.
    ///  2. The result must hold EVERY column the tag stored. A partial overlap can
    ///     match exactly one row and still match the WRONG row — a tag made on a
    ///     `status` value would find the only other row with that status. The
    ///     full-set rule needs no arbitrary constant.
    ///  3. A fingerprint that matches more than one row tags none of them, and the
    ///     mirror case: a row that more than one fingerprint tag claims tags neither.
    ///     Picking a winner either way would put a highlight on a row, or under a
    ///     label, the user did not choose.
    ///
    ///     The two halves of rule 3 compose in order, not independently: a
    ///     fingerprint disqualified by the first half is removed from contention
    ///     before the second half ever runs, so it does not poison a row it
    ///     touched — it just stops competing for it. A vaguer tag (say, on
    ///     `status` alone) that matches two rows is dropped by the first half; a
    ///     more specific tag that uniquely matches one of those same rows still
    ///     claims it, because by the time the second half runs, the vaguer tag
    ///     never made a claim there at all.
    ///
    /// Tags are grouped by their table and stored column set, so each group builds
    /// its own canonical string per row and the encoder runs once per row per group
    /// rather than once per row per tag.
    private static func matchWeak(
        identity: RowIdentity,
        columns: [String],
        rows: [[String?]],
        tagsByIdentity: [String: RowTag]
    ) -> [Int: RowTag] {
        let present = Set(columns)
        let resultTables = Set(identity.tableKeys)

        let eligible = eligibleTags(in: tagsByIdentity, presentColumns: present, resultTables: resultTables)
        guard !eligible.isEmpty else { return [:] }

        // Column index per name, so a row's values can be read in the stored order.
        var indexOf: [String: Int] = [:]
        for (i, name) in columns.enumerated() where indexOf[name] == nil { indexOf[name] = i }

        // Row -> the tags claiming it. Claims are collected across ALL groups before
        // `unambiguousClaims` applies rule 3's second half, because a row claimed by
        // more than one tag is refused and that cannot be decided one group at a
        // time.
        var claimsByRow: [Int: [RowTag]] = [:]
        for group in Dictionary(grouping: eligible, by: { tag in
            FingerprintGroup(tableKey: tag.tableKey,
                             columns: tag.identityColumns.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        }) {
            // The group's OWN key, not any member tag's stored order. `eligibleTags`
            // returns `Array(byId.values)`, whose order is not guaranteed, and
            // `Dictionary(grouping:by:)` preserves that order inside each bucket —
            // so picking a member tag's `identityColumns` here would vary between
            // processes. `group.key.columns` is deterministic by construction
            // (sorted). `indices` and the `encode` call below both then read this
            // same order and stay positionally aligned, and `encode` canonicalises
            // by UTF-8 bytes regardless, so the row string still equals the stored
            // string whatever order either side used.
            let groupColumns = group.key.columns
            let indices = groupColumns.compactMap { indexOf[$0] }
            // `indices` is short only when a column is ABSENT from the result —
            // never from a duplicated name, which still yields one index per
            // occurrence (mapped to the SAME index, since `indexOf` keeps only the
            // first). If a tag's own `identityColumns` repeats a name, the built
            // string reads one column's value twice and will not equal the stored
            // fingerprint, which was built from two different values. That is a
            // MISSED match, not a wrong one — the safe direction — so it is left
            // as is.
            //
            // This guard is what actually ENFORCES rule 2. The subset filter in
            // `eligibleTags` is an early-out that avoids grouping ineligible tags;
            // it is not load-bearing, because `indexOf`'s keys are exactly the
            // result's columns, so `indices.count == groupColumns.count` is the
            // same test. Weakening that filter alone therefore changes nothing
            // observable — that is by design, not an untested branch.
            guard indices.count == groupColumns.count else { continue }

            for (row, tag) in claims(groupColumns: groupColumns, indices: indices,
                                     tags: group.value, rows: rows) {
                claimsByRow[row, default: []].append(tag)
            }
        }

        return unambiguousClaims(claimsByRow)
    }

    /// Rules 1 and 2's early-out, plus distinctness: a strong tag holds two keys,
    /// so it appears twice in `tagsByIdentity.values` now that eligibility no
    /// longer filters on kind, and keying by `tag.id` collapses that back to one.
    /// The dedup is precautionary — a strong tag contributes no fingerprint key and
    /// is dropped downstream either way — but it keeps the result a set of
    /// distinct tags, which the claim-counting in `matchWeak` reads more simply.
    ///
    /// Keyed by `tag.id` rather than a separate `seen` set alongside `append`: it
    /// says "distinct by id" directly, and avoids a `where` clause reading a set
    /// that the loop body mutates.
    private static func eligibleTags(
        in tagsByIdentity: [String: RowTag],
        presentColumns: Set<String>,
        resultTables: Set<String>
    ) -> [RowTag] {
        var byId: [String: RowTag] = [:]
        // rule 2's early-out; see matchWeak's `indices` guard for what actually
        // enforces it
        for tag in tagsByIdentity.values
        where resultTables.contains(tag.tableKey)                        // rule 1
            && tag.identityColumns.allSatisfy(presentColumns.contains) { // rule 2
            byId[tag.id] = tag
        }
        return Array(byId.values)
    }

    /// Rule 3's first half, for one fingerprint group: a stored key matching
    /// exactly one row claims it. Returns each claim as `(row, tag)`; the caller
    /// collects claims across every group before `unambiguousClaims` applies the
    /// second half.
    private static func claims(
        groupColumns: [String],
        indices: [Int],
        tags: [RowTag],
        rows: [[String?]]
    ) -> [(row: Int, tag: RowTag)] {
        // The stored key for each tag in this group.
        var tagByKey: [String: RowTag] = [:]
        for tag in tags {
            // Selecting by kind is correct rather than merely defensive: a tag may
            // hold several keys and only the fingerprint one belongs here. A strong
            // key could not be mistaken for a fingerprint anyway — the core writes
            // strong keys starting "V" or "N" (encode_field in row_identity.rs),
            // and a fingerprint always starts "K" because it begins with a column.
            // The two namespaces are disjoint.
            guard let key = tag.keys.first(where: { $0.identityKind == "fingerprint" })?.identityValue
            else { continue }
            // This guard CAN trip: it reads the STORED key from `tag.keys`, and a
            // tag written with an empty fingerprint value would trip it. What is
            // unreachable is any EFFECT of that: the row side never produces "" —
            // `RowFingerprint.encode` always starts with a `K` field for a
            // non-empty column list — so a stored empty key could never have
            // matched a row anyway. Kept for symmetry with the strong path's
            // empty-key sentinel, which IS load-bearing there.
            guard !key.isEmpty else { continue }
            // `tagByKey[key] = tag` is last-write-wins, but two DIFFERENT tags
            // never actually reach here holding the same key: one group means one
            // `tableKey` AND one column multiset — guaranteed by `FingerprintGroup`'s
            // sorted key — and the kind is fixed at "fingerprint", so two tags
            // sharing a fingerprint string would also share a `compositeKey` — and
            // the store index already holds only one tag per composite key, so
            // this never overwrites a different tag in practice.
            tagByKey[key] = tag
        }
        guard !tagByKey.isEmpty else { return [] }

        // Count the rows each key matches, then keep only the unique ones.
        var rowsByKey: [String: [Int]] = [:]
        for (rowIndex, row) in rows.enumerated() {
            let values = indices.map { $0 < row.count ? row[$0] : nil }
            guard let key = RowFingerprint.encode(columns: groupColumns, values: values),
                  tagByKey[key] != nil else { continue }
            rowsByKey[key, default: []].append(rowIndex)
        }
        var out: [(row: Int, tag: RowTag)] = []
        for (key, matched) in rowsByKey where matched.count == 1 { // rule 3, one key -> one row
            if let tag = tagByKey[key] { out.append((matched[0], tag)) }
        }
        return out
    }

    /// Rule 3's second half: one row -> one tag. A row that two tags both claim is
    /// ambiguous, and neither is applied.
    ///
    /// Two fingerprint tags CAN legitimately both survive to this point and claim
    /// the same row — one stored on `["id"]`, another on `["id","name"]` — because
    /// the core's key-set-aware write only replaces a tag matching the SAME key,
    /// and those two have different fingerprint strings. Picking the narrower or
    /// the wider one would need a ranking rule this design does not have, and
    /// picking by group order would make the label change between runs of the same
    /// query. Refusing is the conservative direction, and it matches the first
    /// half of rule 3 in `matchWeak`.
    ///
    /// Comparing tag IDs, not tags directly: `RowTag` is not `Hashable`, so
    /// `Set(tags)` would not compile. The id-set is not what MAKES a duplicate
    /// arrival safe, though — a duplicate cannot happen here regardless of it. A
    /// tag lands in exactly one group (`identityColumns` is fixed per tag), and
    /// `claims` keys its lookup by that tag's one fingerprint string, so a single
    /// tag contributes at most one claim per row. `Set(...).count == 1` is simply
    /// "are all of this row's claims the same tag" — the id is only the `Hashable`
    /// stand-in `RowTag` itself does not provide.
    private static func unambiguousClaims(_ claimsByRow: [Int: [RowTag]]) -> [Int: RowTag] {
        var out: [Int: RowTag] = [:]
        for (row, tags) in claimsByRow where Set(tags.map { $0.id }).count == 1 {
            out[row] = tags[0]
        }
        return out
    }
}
