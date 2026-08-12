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
    static func compositeKey(tableKey: String, kind: String, value: String) -> String {
        "\(tableKey)\u{1}\(kind)\u{1}\(value)"
    }

    /// Tags by index into `rows`.
    ///
    /// - Parameters:
    ///   - identity: the result's block, or nil when the result has no source table.
    ///   - rowCount: the loaded row count. Taken separately because the weak path
    ///     needs `rows` and the strong path does not.
    ///   - columns: result column names, for the weak path only.
    ///   - rows: result values as text, for the weak path only.
    ///   - tagsByIdentity: the store's index.
    static func match(
        identity: RowIdentity?,
        rowCount: Int,
        columns: [String],
        rows: [[String?]],
        tagsByIdentity: [String: RowTag]
    ) -> [Int: RowTag] {
        // The common case, and it must cost nothing: nothing is tagged.
        guard !tagsByIdentity.isEmpty else { return [:] }
        guard let identity else { return [:] }

        if identity.candidates.isEmpty {
            return matchWeak(identity: identity, columns: columns, rows: rows,
                             tagsByIdentity: tagsByIdentity)
        }
        return matchStrong(identity: identity, rowCount: rowCount,
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

    /// Replaced in Task 3. The strong-path tests never reach this.
    private static func matchWeak(
        identity: RowIdentity,
        columns: [String],
        rows: [[String?]],
        tagsByIdentity: [String: RowTag]
    ) -> [Int: RowTag] {
        [:]
    }
}
