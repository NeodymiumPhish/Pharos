import Foundation

/// Which card each of a workspace's stored results goes back on when the
/// workspace reopens.
///
/// A result names its card (`cardId`). A result recorded before cards existed,
/// or whose card has since been deleted, goes on the first card whose SQL is
/// the SQL it ran. Only succeeded results are placed, and the newest result of
/// a card wins.
///
/// The reopen asks `keptResultIds` before it fetches any result blob: each
/// fetch is a gzip+JSON FFI round trip, and a blob of a result that a newer run
/// of the same card replaces would be decoded only to be dropped.
enum WorkspaceResultPlacement {

    struct Placement {
        let meta: WorkspaceResultMeta
        let cardId: String
    }

    /// Every succeeded result that finds a card, oldest first (by
    /// `resultOrder`). A card can appear more than once; the last wins.
    static func placements(of metas: [WorkspaceResultMeta], in document: CardDocument) -> [Placement] {
        metas.sorted(by: { ($0.resultOrder ?? 0) < ($1.resultOrder ?? 0) })
            .filter(\.isSucceeded)
            .compactMap { meta in
                let cardId = meta.cardId.flatMap { id in document.card(id) != nil ? id : nil }
                    ?? document.cards.first(where: { cardMatches($0, meta) })?.id
                return cardId.map { Placement(meta: meta, cardId: $0) }
            }
    }

    /// The ids of the results that end up on a card: the newest placed result
    /// of each card.
    static func keptResultIds(of metas: [WorkspaceResultMeta], in document: CardDocument) -> Set<String> {
        var newest: [String: String] = [:]
        for p in placements(of: metas, in: document) { newest[p.cardId] = p.meta.id }
        return Set(newest.values)
    }

    /// True when `card` holds the SQL `meta` ran, as typed or as rendered,
    /// ignoring whitespace.
    static func cardMatches(_ card: QueryCard, _ meta: WorkspaceResultMeta) -> Bool {
        let sql = CardDocument.normalized(card.sql)
        return sql == CardDocument.normalized(meta.rawSql ?? meta.sql)
            || sql == CardDocument.normalized(meta.sql)
    }
}
