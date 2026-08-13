import Foundation

// MARK: - TagComposer

/// Composes the write payload for a tag on one row. The creation mirror of
/// `TagMatcher`: the same tiers, the same empty-key sentinel, and the same
/// one-producer rule — the strong keys were built by the core and are copied
/// verbatim from the identity block; only the fingerprint is encoded here.
///
/// Pure and offline-tested. The grid supplies the row and decides what to do
/// with a `Failure`; this type only composes.
enum TagComposer {

    enum Failure: Error, Equatable {
        /// The result carries no identity block: no column has a source table.
        /// The UI disables tagging with "This result has no source table."
        case noSourceTable
        /// Every candidate gave this row an empty key (NULL key values from an
        /// outer join). "This row has no key value."
        case noKeyValue
        /// The block and the row disagree about shape — a core bug. Degrade,
        /// never trap.
        case malformedRow
    }

    static func upsert(
        row: Int,
        columns: [String],
        rowValues: [String?],
        identity: RowIdentity?,
        connectionId: String,
        labelId: String,
        note: String?
    ) -> Result<UpsertRowTag, Failure> {
        guard let identity else { return .failure(.noSourceTable) }

        if identity.candidates.isEmpty {
            return fingerprint(columns: columns, rowValues: rowValues,
                               identity: identity, connectionId: connectionId,
                               labelId: labelId, note: note)
        }
        return strong(row: row, columns: columns, rowValues: rowValues,
                      identity: identity, connectionId: connectionId,
                      labelId: labelId, note: note)
    }

    /// The strong tiers. One `RowTagKey` per candidate that holds a non-empty
    /// key for this row; the first contributor is the primary and supplies the
    /// display columns and values.
    private static func strong(
        row: Int, columns: [String], rowValues: [String?],
        identity: RowIdentity, connectionId: String, labelId: String, note: String?
    ) -> Result<UpsertRowTag, Failure> {
        var keys: [RowTagKey] = []
        var primary: KeySet?
        for candidate in identity.candidates {
            guard row < candidate.keys.count else { continue }
            let key = candidate.keys[row]
            // The empty string is the core's "no identity here" sentinel.
            guard !key.isEmpty else { continue }
            keys.append(RowTagKey(identityKind: candidate.kind, identityValue: key))
            if primary == nil { primary = candidate }
        }
        guard let primary, !keys.isEmpty else { return .failure(.noKeyValue) }

        // The primary candidate's key columns, with this row's values. The
        // core only emits a candidate when the result carries every one of its
        // columns, so a miss here is a malformed block.
        var values: [String?] = []
        for name in primary.keyColumns {
            guard let idx = columns.firstIndex(of: name), idx < rowValues.count else {
                return .failure(.malformedRow)
            }
            values.append(rowValues[idx])
        }
        return .success(UpsertRowTag(
            connectionId: connectionId, labelId: labelId, note: note,
            primaryKind: primary.kind, tableKey: identity.tableKey,
            tableDisplay: identity.tableDisplay,
            identityColumns: primary.keyColumns, identityValues: values,
            keys: keys))
    }

    /// The weak tier: the whole row is the identity, and Swift is the only
    /// encoder of a fingerprint.
    private static func fingerprint(
        columns: [String], rowValues: [String?],
        identity: RowIdentity, connectionId: String, labelId: String, note: String?
    ) -> Result<UpsertRowTag, Failure> {
        guard let key = RowFingerprint.encode(columns: columns, values: rowValues) else {
            return .failure(.malformedRow)
        }
        return .success(UpsertRowTag(
            connectionId: connectionId, labelId: labelId, note: note,
            primaryKind: "fingerprint", tableKey: identity.tableKey,
            tableDisplay: identity.tableDisplay,
            identityColumns: columns, identityValues: rowValues,
            keys: [RowTagKey(identityKind: "fingerprint", identityValue: key)]))
    }
}
