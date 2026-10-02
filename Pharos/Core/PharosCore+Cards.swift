import CPharosCore
import Foundation

/// Query cards to and from SQL text, through pharos-core (`commands/cards.rs`):
/// a `.sql` file, an older tab's text, and the flat text kept for search.
extension PharosCore {

    /// One card read from text. camelCase, as the core sends it.
    struct SplitCard: Decodable, Equatable {
        let name: String?
        let version: UInt32?
        let locked: Bool
        let sql: String
        let kind: String
        /// Cards with the same number are versions of one query, in order.
        let lineage: UInt32
        /// 1-based lines of the statement in the text; 0 for a version that
        /// was written as comments.
        let startLine: UInt32
        let endLine: UInt32
    }

    /// Which cards to write.
    enum CardTextMode: String, Encodable {
        /// Every version: `.sql` files, workspace and session text.
        case all
        /// The latest version of each query: a clean script, for a saved
        /// query's text, Spotlight and Shortcuts.
        case latest
    }

    private struct SplitResponse: Decodable { let cards: [SplitCard] }

    private struct CardToWrite: Encodable {
        let name: String?
        let version: Int
        let locked: Bool
        let sql: String
        let kind: String
        let lineageId: String
    }

    private struct SerializeRequest: Encodable {
        let cards: [CardToWrite]
        let mode: CardTextMode
    }

    private struct SerializeResponse: Decodable { let text: String }

    /// The cards in `text`. Empty when the core cannot answer.
    static func splitCards(_ text: String) -> [SplitCard] {
        do {
            let response: SplitResponse = try callSync { text.withCString { pharos_cards_split($0) } }
            return response.cards
        } catch {
            Log.query.error("Card split failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// `cards` as SQL text. Empty when the core cannot answer.
    static func serializeCards(_ cards: [QueryCard], mode: CardTextMode) -> String {
        let request = SerializeRequest(
            cards: cards.map {
                CardToWrite(name: $0.name, version: $0.version, locked: $0.isLocked, sql: $0.sql,
                            kind: $0.kind.rawValue, lineageId: $0.lineageId)
            },
            mode: mode)
        do {
            let response: SerializeResponse = try callSync(input: request) { pharos_cards_serialize($0) }
            return response.text
        } catch {
            Log.query.error("Card serialize failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }
}

/// A tab's cards as text, and text as a tab's cards.
enum CardText {

    /// One card per statement of `text`, with the names, versions and locks
    /// its `-- name:` / `-- version:` headers give. Blank text is one blank
    /// draft.
    static func document(from text: String) -> CardDocument {
        let split = PharosCore.splitCards(text)
        guard !split.isEmpty else {
            // Text the core could not split (or none at all) stays in one
            // card rather than being lost.
            var doc = CardDocument()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                doc.updateSQL(cardId: doc.cards[0].id, text)
            }
            return doc
        }
        var lineageIds: [UInt32: String] = [:]
        let cards: [QueryCard] = split.map { s in
            let id = UUID().uuidString
            let lineage = lineageIds[s.lineage] ?? id
            lineageIds[s.lineage] = lineage
            var card = QueryCard(id: id, lineageId: lineage, version: Int(s.version ?? 1), name: s.name,
                                 sql: s.sql, kind: QueryCardKind(rawValue: s.kind) ?? .sql)
            card.isLocked = s.locked
            return card
        }
        return CardDocument(cards: cards)
    }

    /// The document as SQL text.
    static func text(of document: CardDocument, mode: PharosCore.CardTextMode = .all) -> String {
        PharosCore.serializeCards(document.cards, mode: mode)
    }
}
