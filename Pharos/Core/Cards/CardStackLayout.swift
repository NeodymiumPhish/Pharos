import CoreGraphics
import Foundation

/// One row of the card stack.
enum CardStackItem: Hashable {
    case card(String)
    /// Older versions of one query, folded into one row.
    case versionGroup(lineageId: String, cardIds: [String])
    /// The "New query card" button at the end.
    case addCard
}

/// The card stack's rows and their frames. Pure geometry: the stack view
/// places its subviews at these frames, in a flipped document view.
///
/// Manual frames, not a stack or collection view: a stack view builds and lays
/// out every card's editor at once, and a collection view recycles views,
/// which would move one card's undo history and caret to another card.
enum CardStackLayout {
    /// The rows for `document`. Older locked versions of a query fold into one
    /// row above its latest version, unless the user opened that query, or the
    /// card is focused or showing its results. A filter shows the matching
    /// cards only, versions included, and no add button.
    static func items(_ document: CardDocument, filter: String? = nil) -> [CardStackItem] {
        let needle = filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !needle.isEmpty {
            return document.cards
                .filter { ($0.name ?? "").localizedCaseInsensitiveContains(needle) || $0.sql.localizedCaseInsensitiveContains(needle) }
                .map { .card($0.id) }
        }

        var lastOfLineage: [String: String] = [:]
        for card in document.cards { lastOfLineage[card.lineageId] = card.id }

        func folds(_ card: QueryCard) -> Bool {
            card.isLocked
                && lastOfLineage[card.lineageId] != card.id
                && !document.expandedLineages.contains(card.lineageId)
                && card.id != document.focusedCardId
                && card.id != document.displayedCardId
        }

        var items: [CardStackItem] = []
        for card in document.cards {
            guard folds(card) else {
                items.append(.card(card.id))
                continue
            }
            // Consecutive folded versions of one query share a row.
            if case let .versionGroup(lineage, ids)? = items.last, lineage == card.lineageId {
                items[items.count - 1] = .versionGroup(lineageId: lineage, cardIds: ids + [card.id])
            } else {
                items.append(.versionGroup(lineageId: card.lineageId, cardIds: [card.id]))
            }
        }
        items.append(.addCard)
        return items
    }

    /// Top-down frames: `inset` around the stack, `spacing` between rows.
    static func frames(_ items: [CardStackItem], height: (CardStackItem) -> CGFloat,
                       width: CGFloat, spacing: CGFloat, inset: CGFloat) -> [CGRect] {
        var y = inset
        let w = max(0, width - inset * 2)
        return items.map { item in
            let h = height(item)
            defer { y += h + spacing }
            return CGRect(x: inset, y: y, width: w, height: h)
        }
    }

    /// The document height for `frames`, bottom inset included.
    static func contentHeight(_ frames: [CGRect], inset: CGFloat) -> CGFloat {
        (frames.last?.maxY ?? inset) + inset
    }

    /// The rows that intersect `visible` (a contiguous range, as rows stack).
    static func visibleIndices(_ frames: [CGRect], visible: CGRect) -> Range<Int> {
        guard let first = frames.firstIndex(where: { $0.maxY > visible.minY }) else { return 0..<0 }
        let end = frames[first...].firstIndex(where: { $0.minY >= visible.maxY }) ?? frames.count
        return first..<max(first, end)
    }

    /// The scroll offset that keeps `anchor` at the same place on screen after
    /// rows above it appear, go or change height.
    static func anchoredOffset(oldItems: [CardStackItem], oldFrames: [CGRect],
                               newItems: [CardStackItem], newFrames: [CGRect],
                               anchor: CardStackItem, oldOffset: CGFloat) -> CGFloat {
        guard let o = oldItems.firstIndex(of: anchor), let n = newItems.firstIndex(of: anchor),
              o < oldFrames.count, n < newFrames.count else { return oldOffset }
        return max(0, oldOffset + newFrames[n].minY - oldFrames[o].minY)
    }
}
