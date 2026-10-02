import Foundation

/// Find across cards searches one string: every findable card's SQL, in stack
/// order, joined by a newline that belongs to no card (so a match never runs
/// from one card into the next). This maps between that string and each card.
/// Lengths are UTF-16 units, as NSString and NSTextFinder count them.
/// Pure (Foundation only), so the mapping is tested without AppKit.
struct CardFindIndex: Equatable {
    struct Segment: Equatable {
        let cardId: String
        /// The card's range in `text`.
        let range: NSRange
    }

    let text: String
    let segments: [Segment]

    init(cards: [(id: String, sql: String)]) {
        var segments: [Segment] = []
        var location = 0
        var parts: [String] = []
        for (i, card) in cards.enumerated() {
            if i > 0 { location += 1 }          // the separator
            let length = (card.sql as NSString).length
            segments.append(Segment(cardId: card.id, range: NSRange(location: location, length: length)))
            location += length
            parts.append(card.sql)
        }
        self.segments = segments
        self.text = parts.joined(separator: "\n")
    }

    var length: Int { (text as NSString).length }

    /// The card a character of `text` belongs to. The separator after a card,
    /// and the end of the text, belong to the card before them.
    func segment(at index: Int) -> Segment? {
        guard !segments.isEmpty else { return nil }
        var found = segments[0]
        for s in segments where s.range.location <= index { found = s }
        return found
    }

    /// A range of `text` in its card's own terms, or nil when it crosses cards.
    func local(_ range: NSRange) -> (cardId: String, range: NSRange)? {
        guard let s = segment(at: range.location),
              range.location >= s.range.location,
              NSMaxRange(range) <= NSMaxRange(s.range) else { return nil }
        return (s.cardId, NSRange(location: range.location - s.range.location, length: range.length))
    }

    /// A card's own range in `text`; nil for a card that is not indexed.
    func global(cardId: String, _ range: NSRange) -> NSRange? {
        guard let s = segments.first(where: { $0.cardId == cardId }) else { return nil }
        let location = min(s.range.location + range.location, NSMaxRange(s.range))
        let length = min(range.length, NSMaxRange(s.range) - location)
        return NSRange(location: location, length: max(0, length))
    }
}
