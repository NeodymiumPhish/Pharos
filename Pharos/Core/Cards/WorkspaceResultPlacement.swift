import Foundation

/// Which card each of a workspace's stored results goes back on when the
/// workspace reopens.
///
/// A result goes back only on the card it names (`cardId`), never on another
/// card with the same SQL: that card may run against another database or
/// schema. A result whose card is gone, or recorded before cards existed, goes
/// on no card. Only succeeded results are placed, and the newest result of a
/// card wins.
///
/// The reopen asks `keptResultIds` before it fetches any result blob: each
/// fetch is a gzip+JSON FFI round trip, and a blob of a result that a newer run
/// of the same card replaces would be decoded only to be dropped.
enum WorkspaceResultPlacement {

    struct Placement {
        let meta: WorkspaceResultMeta
        let cardId: String
    }

    /// Every succeeded result whose card is in `document`, oldest first (by
    /// `resultOrder`). A card can appear more than once; the last wins.
    static func placements(of metas: [WorkspaceResultMeta], in document: CardDocument) -> [Placement] {
        metas.sorted(by: { ($0.resultOrder ?? 0) < ($1.resultOrder ?? 0) })
            .filter(\.isSucceeded)
            .compactMap { meta in
                guard let cardId = meta.cardId, document.card(cardId) != nil else { return nil }
                return Placement(meta: meta, cardId: cardId)
            }
    }

    /// The ids of the results that end up on a card: the newest placed result
    /// of each card.
    static func keptResultIds(of metas: [WorkspaceResultMeta], in document: CardDocument) -> Set<String> {
        var newest: [String: String] = [:]
        for p in placements(of: metas, in: document) { newest[p.cardId] = p.meta.id }
        return Set(newest.values)
    }
}
