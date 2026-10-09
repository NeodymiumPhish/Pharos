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
        /// The query's notes, from a notes block; every version has them.
        let notes: String?
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
        /// Written once, with the query's latest version.
        let notes: String?
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
                            kind: $0.kind.rawValue, lineageId: $0.lineageId, notes: $0.hasNotes ? $0.notes : nil)
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

    private struct ExtractNotesResponse: Decodable {
        let notes: String?
        let sql: String
    }

    /// The comments before a card's statement as notes, and the SQL without
    /// them: comment marks, `=` border lines and `-- name:` / `-- version:`
    /// lines removed. nil when no comment comes before a statement, or the
    /// core cannot answer.
    static func extractLeadingNotes(_ sql: String) -> (notes: String, sql: String)? {
        do {
            let response: ExtractNotesResponse = try callSync { sql.withCString { pharos_cards_extract_notes($0) } }
            guard let notes = response.notes else { return nil }
            return (notes, response.sql)
        } catch {
            Log.query.error("Card notes extract failed: \(error.localizedDescription, privacy: .public)")
            return nil
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
            card.notes = s.notes
            return card
        }
        return CardDocument(cards: cards)
    }

    /// `document(from:)` for a `.sql` file the user opens: each card with
    /// comments before its statement offers to move them into its notes
    /// (`QueryCard.offersCommentImport`).
    static func document(fromFile text: String) -> CardDocument {
        var document = document(from: text)
        for i in document.cards.indices {
            let card = document.cards[i]
            guard card.kind == .sql, !card.isLocked, !card.hasNotes,
                  PharosCore.extractLeadingNotes(card.sql) != nil else { continue }
            document.cards[i].offersCommentImport = true
        }
        return document
    }

    /// The document as a script to run elsewhere: each card's `{{name}}`
    /// tokens replaced by the variables' values. Notes keep their tokens:
    /// they are text about the query, not part of what runs.
    static func renderedText(of document: CardDocument, mode: PharosCore.CardTextMode = .latest,
                             variables: [QueryVariable]) -> String {
        var rendered = document
        for i in rendered.cards.indices {
            rendered.cards[i].sql = VariableSubstitutor.render(rendered.cards[i].sql, with: variables).sql
        }
        return text(of: rendered, mode: mode)
    }

    /// `renderedText(of:)` for a saved Session's stored text and cards. A
    /// Session without notes renders its text as stored, so its output stays
    /// what it always was.
    static func renderedText(storedSQL sql: String, cardsJson: String?, variables: [QueryVariable]) -> String {
        let document = CardPersistence.decode(json: cardsJson, text: sql)
        guard document.cards.contains(where: \.hasNotes) else {
            return VariableSubstitutor.render(sql, with: variables).sql
        }
        return renderedText(of: document, mode: .latest, variables: variables)
    }

    /// The document as SQL text.
    static func text(of document: CardDocument, mode: PharosCore.CardTextMode = .all) -> String {
        PharosCore.serializeCards(document.cards, mode: mode)
    }
}
