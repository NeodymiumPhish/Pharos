import AppKit

// MARK: - TagPalette

/// The results grid's tag READ MODEL, and the fixed colour palette behind it.
///
/// The palette part: a tag stores a `colorIndex`, not a hex string, so the
/// stored value stays meaningful when the palette is restyled and cannot carry
/// an unreadable colour. An out-of-range index wraps rather than trapping,
/// because the value comes from the database.
///
/// The read-model part: everything the grid paints for a tag — the bar's
/// bands, the row tooltip, and the matched-cell tints — is decided HERE, by
/// `bake(tags:matchesByRow:)`, once per landed tag map. Two reasons, and the
/// first is correctness, not speed:
///
/// - One survivor rule. A tag deleted mid-repaint must disappear from the
///   bands, the tooltip line AND the cell tint together. When each output
///   filtered on its own, they could disagree in ONE direction — a row
///   showing a band for a tag whose matched cell had already lost its tint.
///   (Never the reverse: a tint needs an entry in `tints`, which only a live
///   tag has.) One direction was enough.
/// - `ResultsDataSource` then does dictionary lookups only. No colour, string
///   or match work runs per cell or per row on the scroll path.
///
/// Pure and AppKit-light on purpose: the data source is too entangled to
/// compile in a standalone harness, so anything worth testing lives here. See
/// `scripts/test-tag-appearance.sh`.
enum TagPalette {
    static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow,
        .systemGreen, .systemBlue, .systemPurple,
    ]

    /// Wrap a stored index into the palette's range, or nil when there is no
    /// palette to wrap into.
    ///
    /// The one place the wrap-around lives. The value comes from the database,
    /// so it can be anything — including negative, which is why this is not a
    /// plain `%`.
    static func normalizedColorIndex(_ index: Int) -> Int? {
        guard !colors.isEmpty else { return nil }
        return ((index % colors.count) + colors.count) % colors.count
    }

    static func color(at index: Int) -> NSColor {
        guard let normalized = normalizedColorIndex(index) else { return .systemGray }
        return colors[normalized]
    }

    /// One vertical band of the leading bar.
    struct Segment: Equatable {
        let color: NSColor
        let isPartial: Bool
    }

    /// The bar caps at three bands (spec, Rendering); the tooltip and the
    /// Inspector carry the full list.
    static let maxSegments = 3

    /// Matched-cell tint alpha. Above the 0.15 row wash so a matched cell
    /// reads against the wash, and below the CURRENT find match's 0.3 so the
    /// match the user is looking at is also the loudest fill on screen.
    ///
    /// It is NOT below every find state: an OTHER (non-current) find match
    /// paints at 0.1, weaker on screen than this tint even though find wins
    /// the precedence chain in `ResultsDataSource.viewFor` and takes the cell.
    /// Precedence and loudness disagree there by choice — a non-current find
    /// match is told apart by its BORDER, not by its fill, and a tag tint
    /// never draws one. See `FindMatchDecoration`, which owns both find
    /// numbers; `TagAppearanceTests` asserts this ordering against them rather
    /// than against a literal, so the prose here cannot quietly rot.
    static let cellTintAlpha: CGFloat = 0.2

    private static let swatchSize = NSSize(width: 12, height: 12)

    /// One dot per palette entry, drawn once.
    ///
    /// A `static let` rather than a mutable cache: the domain is the palette,
    /// which never changes at run time, so the whole set can be built on first
    /// touch and handed out for ever after. `TagManageSheet` asks for one per
    /// row draw, and drawing an `NSImage` per draw is the kind of allocation a
    /// scrolling list should never make.
    private static let swatches: [NSImage] = colors.indices.map { index in
        NSImage(size: swatchSize, flipped: false) { rect in
            colors[index].setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    /// A 12pt colour dot for popups, segmented controls, and list rows.
    static func swatch(colorIndex: Int) -> NSImage {
        guard let normalized = normalizedColorIndex(colorIndex) else {
            return NSImage(size: swatchSize)
        }
        return swatches[normalized]
    }

    // MARK: - Selection repair

    /// Which row a list should select after the row at `removedRow` is gone,
    /// or nil when nothing is left to select.
    ///
    /// The rule is "stay put": the next item slides into the removed row's
    /// index and inherits the selection, and removing the LAST item falls back
    /// one to the new last. Deleting down a list therefore walks steadily
    /// downwards instead of jumping to the top on the final item.
    ///
    /// Pure, and here rather than in the sheet, because the alternative was to
    /// lean on `NSTableView` clipping an out-of-range selection during
    /// `reloadData()` — behaviour AppKit does not promise. If it ever stopped
    /// clipping, the sheet would show a drawn selection with empty disabled
    /// fields and no way to tell why. An explicit rule cannot rot that way, and
    /// this is the only part of the manage sheet a harness can reach.
    static func selectionAfterRemoval(removedRow: Int, newCount: Int) -> Int? {
        guard newCount > 0 else { return nil }
        guard removedRow > 0 else { return 0 }
        return min(removedRow, newCount - 1)
    }

    // MARK: - Per-row primitives
    //
    // Each takes ONE row's matches, in `TagTupleMatcher.ordered`'s
    // strongest-first order, and never sorts them. `bake` composes all three;
    // they stay separate so each rule can be tested on its own.

    /// The bar's bands for one row, strongest first, capped at `maxSegments`.
    /// Empty when the row is untagged.
    ///
    /// A tag id missing from `tagColors` (a delete landing mid-repaint) is
    /// filtered out BEFORE the cap, so a colourless tag never steals a slot
    /// from a coloured one behind it.
    static func segments(matches: [TagRowMatch], tagColors: [String: NSColor]) -> [Segment] {
        Array(
            matches
                .compactMap { match in
                    tagColors[match.tagId].map {
                        Segment(color: $0, isPartial: match.state == .dashed)
                    }
                }
                .prefix(maxSegments)
        )
    }

    /// The full tag list for a row's tooltip, one "Name — state" line per
    /// matching tag, in the matcher's order and UNCAPPED — this is where a row
    /// with more than `maxSegments` tags discloses the ones the bar could not
    /// draw. Nil when the row is untagged or every matching tag has been
    /// deleted mid-repaint.
    ///
    /// A tag id missing from `tagNames` is dropped, not shown as "Unnamed
    /// tag": `tagNames` and `tagColors` are built together from the same tag
    /// list in one `bake`, so a missing name and a missing colour are the SAME
    /// condition (a deleted tag) — `segments` already skips that tag's band,
    /// and the tooltip must agree rather than naming a tag that no longer
    /// exists.
    static func tooltip(matches: [TagRowMatch], tagNames: [String: String]) -> String? {
        // Escaped per NAME, never on the joined result: the `\n` at the join is
        // ours, and a tag name in the store can predate the input sanitiser.
        let lines = matches.compactMap { match in
            tagNames[match.tagId].map { "\(DisplayEscape.escaped($0)) — \(match.state == .solid ? "solid" : "dashed")" }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Which tag tints each DATA column of one row: the strongest match that
    /// matched the column claims it. `matches` must already be in the
    /// matcher's strongest-first order.
    static func tintTagByColumn(matches: [TagRowMatch]) -> [Int: String] {
        var map: [Int: String] = [:]
        for match in matches {
            for column in match.matchedColumns where map[column] == nil {
                map[column] = match.tagId
            }
        }
        return map
    }

    // MARK: - The display → data crossing

    /// display row → DATA row, or nil when the row is out of range.
    ///
    /// Everything `bake` returns is keyed by DATA row and every caller in the
    /// grid holds a DISPLAY row, so this crossing happens on the row-view path
    /// and on the cell path. It lives here because it is the grid's worst
    /// silent-failure risk: reversed, the paint lands on the wrong row the
    /// moment a filter or a sort is active, and nothing crashes to say so.
    ///
    /// The bounds guard is not dressing — `displayRows` can be momentarily
    /// stale against the table's row count during a reload, and an unguarded
    /// subscript would trap.
    static func dataRow(displayRow: Int, displayRows: [Int]) -> Int? {
        guard displayRow >= 0, displayRow < displayRows.count else { return nil }
        return displayRows[displayRow]
    }

    /// The tag whose colour tints one DATA column of one DISPLAY row, or nil
    /// when that cell matched nothing. The cell TINT path's whole mapping, so
    /// `ResultsDataSource` cannot hold a private copy of it.
    ///
    /// The cell TOOLTIP does not come through here: it crosses on `viewFor`'s
    /// own `dataRowIdx`, which the cell's TEXT already depends on. A desync
    /// there shows the wrong VALUE in the cell, not merely the wrong tooltip,
    /// so that crossing cannot rot unnoticed and is safe left inline.
    static func tintTag(
        row: Int,
        displayRows: [Int],
        tintByRow: [Int: [Int: String]],
        column: Int
    ) -> String? {
        guard let data = dataRow(displayRow: row, displayRows: displayRows) else { return nil }
        return tintByRow[data]?[column]
    }

    // MARK: - The bake

    /// Everything the grid paints for one landed tag map. All three row-keyed
    /// dictionaries are keyed by DATA row index.
    ///
    /// A tagged row lands in all three in practice, but that is NOT an
    /// invariant `bake` enforces — it leans on an upstream property. A
    /// `TagRowMatch` with an empty `matchedColumns` would take a band and a
    /// tooltip line and contribute no tint entry; `TagTupleMatcher` cannot
    /// produce one, because it fills `matchedColumns` and `touched` in the
    /// same loop body (`TagTupleMatcher.swift`), so a match always carries at
    /// least one column. Do not read row membership here as guaranteed.
    ///
    /// `segmentsByRow` carries plain tuples rather than `Segment`s so
    /// `TaggedRowView` keeps zero non-AppKit dependencies and goes on
    /// compiling in its own harness.
    struct RenderState {
        let segmentsByRow: [Int: [(color: NSColor, isPartial: Bool)]]
        let tooltipByRow: [Int: String]
        let tintByRow: [Int: [Int: String]]
        /// Tint colour per tag id, pre-baked so no render path allocates one.
        let tints: [String: CGColor]
    }

    /// Bake one tag map into everything the grid draws from it.
    ///
    /// The survivor rule is applied ONCE, here: a match whose tag is not in
    /// `tags` is dropped before any output is built, so a tag deleted while
    /// its result is on screen loses its band, its tooltip line and its cell
    /// tint in the same repaint.
    static func bake(tags: [Tag], matchesByRow: [Int: [TagRowMatch]]) -> RenderState {
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: a duplicate tag id
        // would TRAP the app, and these ids come from the database.
        let colors = Dictionary(
            tags.map { ($0.id, color(at: $0.colorIndex)) },
            uniquingKeysWith: { first, _ in first })
        let names = Dictionary(
            tags.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first })
        let live = Set(tags.map(\.id))

        var segmentsByRow: [Int: [(color: NSColor, isPartial: Bool)]] = [:]
        var tooltipByRow: [Int: String] = [:]
        var tintByRow: [Int: [Int: String]] = [:]

        for (dataRow, rowMatches) in matchesByRow {
            let surviving = rowMatches.filter { live.contains($0.tagId) }
            guard !surviving.isEmpty else { continue }

            let bands = segments(matches: surviving, tagColors: colors)
            if !bands.isEmpty {
                segmentsByRow[dataRow] = bands.map { (color: $0.color, isPartial: $0.isPartial) }
            }
            if let line = tooltip(matches: surviving, tagNames: names) {
                tooltipByRow[dataRow] = line
            }
            let tints = tintTagByColumn(matches: surviving)
            if !tints.isEmpty {
                tintByRow[dataRow] = tints
            }
        }

        return RenderState(
            segmentsByRow: segmentsByRow,
            tooltipByRow: tooltipByRow,
            tintByRow: tintByRow,
            tints: colors.mapValues { $0.withAlphaComponent(cellTintAlpha).cgColor })
    }
}
