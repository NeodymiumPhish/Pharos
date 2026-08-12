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
    ///  3. A fingerprint that matches more than one row tags none of them. Picking
    ///     one arbitrarily would put the highlight on a row the user never tagged.
    ///
    /// Tags are grouped by their stored column set, so each group builds its own
    /// canonical string per row and the encoder runs once per row per group rather
    /// than once per row per tag.
    private static func matchWeak(
        identity: RowIdentity,
        columns: [String],
        rows: [[String?]],
        tagsByIdentity: [String: RowTag]
    ) -> [Int: RowTag] {
        let present = Set(columns)
        let resultTables = Set(identity.tableKeys)

        // De-duplicate: a fingerprint tag is indexed under one key, but filtering
        // the index by value would still visit it once per entry.
        var eligible: [RowTag] = []
        var seen = Set<String>()
        for tag in tagsByIdentity.values
        where resultTables.contains(tag.tableKey)                     // rule 1
            && Set(tag.identityColumns).isSubset(of: present)           // rule 2
            && !seen.contains(tag.id) {
            seen.insert(tag.id)
            eligible.append(tag)
        }
        guard !eligible.isEmpty else { return [:] }

        // Column index per name, so a row's values can be read in the stored order.
        var indexOf: [String: Int] = [:]
        for (i, name) in columns.enumerated() where indexOf[name] == nil { indexOf[name] = i }

        var out: [Int: RowTag] = [:]
        for group in Dictionary(grouping: eligible, by: { $0.identityColumns }) {
            let groupColumns = group.key
            let indices = groupColumns.compactMap { indexOf[$0] }
            // A duplicated column name could leave this short; skip rather than
            // build a string that means something else. (If a tag's own
            // `identityColumns` repeats a name, `indexOf` keeps only the FIRST
            // index for that name, so the built string reads one column's value
            // twice and will not equal the stored fingerprint, which was built
            // from two different values. That is a MISSED match, not a wrong
            // one — the safe direction — so it is left as is.)
            //
            // This guard is what actually ENFORCES rule 2. The subset filter above
            // is an early-out that avoids grouping ineligible tags; it is not
            // load-bearing, because `indexOf`'s keys are exactly the result's
            // columns, so `indices.count == groupColumns.count` is the same test.
            // Weakening the filter alone therefore changes nothing observable —
            // that is by design, not an untested branch.
            guard indices.count == groupColumns.count else { continue }

            // The stored key for each tag in this group.
            var tagByKey: [String: RowTag] = [:]
            for tag in group.value {
                // Selecting by kind is correct rather than merely defensive: a tag
                // may hold several keys and only the fingerprint one belongs here.
                // A strong key could not be mistaken for a fingerprint anyway — the
                // core writes strong keys starting "V" or "N" (encode_field in
                // row_identity.rs), and a fingerprint always starts "K" because it
                // begins with a column. The two namespaces are disjoint.
                guard let key = tag.keys.first(where: { $0.identityKind == "fingerprint" })?.identityValue,
                      !key.isEmpty else { continue }
                tagByKey[key] = tag
            }
            guard !tagByKey.isEmpty else { continue }

            // Count the rows each key matches, then apply only the unique ones.
            var rowsByKey: [String: [Int]] = [:]
            for (rowIndex, row) in rows.enumerated() {
                let values = indices.map { $0 < row.count ? row[$0] : nil }
                guard let key = RowFingerprint.encode(columns: groupColumns, values: values),
                      tagByKey[key] != nil else { continue }
                rowsByKey[key, default: []].append(rowIndex)
            }
            for (key, matched) in rowsByKey where matched.count == 1 { // rule 3
                if let tag = tagByKey[key] { out[matched[0]] = tag }
            }
        }
        return out
    }
}
