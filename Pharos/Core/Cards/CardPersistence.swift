import Foundation

/// A tab's cards as they are stored: the document as JSON, beside the same
/// cards as SQL text.
///
/// The text column (a session tab's `sql`, a workspace's `editor_text`, a
/// saved query's `sql`) stays the source for search, Spotlight, Shortcuts and
/// older versions of the app. The JSON carries what text cannot: card ids
/// (results are filed under them), runs, colours, focus. It also carries a
/// hash of the text it was written with: an older app that edits the text
/// leaves the hash behind, and the cards are then split from the text again
/// rather than shown stale.
enum CardPersistence {
    private struct Envelope: Codable {
        var format: Int = 1
        var flatHash: String
        var document: CardDocument
    }

    /// The document as stored text and JSON. `mode` picks the text: every
    /// version, or (for a saved query) the latest of each.
    static func encode(_ document: CardDocument, mode: PharosCore.CardTextMode = .all) -> (text: String, json: String?) {
        let text = CardText.text(of: document, mode: mode)
        let envelope = Envelope(flatHash: fnv1a(text), document: document)
        let json = (try? JSONEncoder.pharos.encode(envelope)).map { String(decoding: $0, as: UTF8.self) }
        return (text, json)
    }

    /// The document stored as `json` beside `text`. Split from the text when
    /// there is no JSON, when it does not decode, or when the text changed
    /// since the JSON was written.
    static func decode(json: String?, text: String) -> CardDocument {
        if let json, let data = json.data(using: .utf8),
           let envelope = try? JSONDecoder.pharos.decode(Envelope.self, from: data),
           envelope.flatHash == fnv1a(text), !envelope.document.cards.isEmpty {
            return envelope.document
        }
        return CardText.document(from: text)
    }

    /// FNV-1a, 64-bit, over the UTF-8 bytes, as hex. Stable across releases
    /// (Swift's own hashing is seeded per process).
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
