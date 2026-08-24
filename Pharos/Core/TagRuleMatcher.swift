import Foundation

// MARK: - Match results

enum TagMatchState: String, Equatable {
    /// Some tuple of this tag is entirely present in the row.
    case solid
    /// At least one captured value is present, but no single tuple is complete.
    case dashed
}

/// One tag's verdict on one row.
struct TagRowMatch: Equatable {
    let tagId: String
    let state: TagMatchState
    /// Result column INDICES whose value matched, ascending. Phase 5 tints them.
    let matchedColumns: [Int]
    /// Every tuple that contributed a matched value, sorted. Phase 5's Inspector
    /// explains a partial match from these.
    let matchedRuleIds: [String]
    /// Tuples entirely present in this row, sorted. Empty when dashed. The
    /// "Remove From Tag" action deletes exactly these.
    let solidRuleIds: [String]
}

// MARK: - TagRuleMatcher

/// Maps the rows of a result to the tags that match them.
///
/// Pure and offline-testable: no AppKit, no FFI, no store. `TagStore` supplies
/// the index and the grid supplies the result; this type only decides.
///
/// The shape is a hash probe, not a scan:
///
///  1. The store builds ONE index over every tuple of every tag, keyed by
///     `(family, normalized value)`. It is rebuilt on a store change, not per
///     result.
///  2. Each result column is classified ONCE. A column whose family no tagged
///     value uses is skipped without normalizing a single cell.
///  3. Each remaining cell is normalized once and probed once.
///
/// So the per-cell cost does not grow with the number of tags or tuples — which
/// is what lets a case hold hundreds of indicators without slowing the grid.
enum TagRuleMatcher {

    /// The probe index. Tags, tuples and slots are held as parallel arrays and
    /// referred to by position: an `Index.Slot` is 24 bytes of `Int`s rather
    /// than three retained strings, and the row walk copies no strings at all
    /// until it builds its verdicts.
    struct Index {
        fileprivate struct Slot {
            let tag: Int
            let rule: Int
            let position: Int
        }
        fileprivate var slots: [TagValueKey: [Slot]] = [:]
        fileprivate var tagIds: [String] = []
        fileprivate var ruleIds: [String] = []
        /// Slot count per tuple — the test for "complete".
        fileprivate var ruleWidth: [Int] = []
        /// Families that appear at all, so an irrelevant column costs nothing.
        fileprivate var families: Set<String> = []

        var isEmpty: Bool { slots.isEmpty }
    }

    /// Build the index from every tag the store holds.
    static func buildIndex(_ tags: [Tag]) -> Index {
        var index = Index()
        for tag in tags {
            let tagSlot = index.tagIds.count
            index.tagIds.append(tag.id)
            for tuple in tag.rules {
                // A tuple with no values contributes no slots, so it can never
                // be touched by a probe. Skipping it here keeps the parallel
                // arrays free of a dead entry — and keeps `ruleWidth` from
                // ever holding a 0, which WOULD read as "every slot satisfied"
                // if a later change ever recorded a tuple without walking its
                // values. A tuple can arrive empty from a corrupt
                // `tuple_values` blob: the Rust CRUD decodes bad JSON to an
                // empty list rather than failing the load.
                guard !tuple.conditions.isEmpty else { continue }
                let ruleSlot = index.ruleIds.count
                index.ruleIds.append(tuple.id)
                index.ruleWidth.append(tuple.conditions.count)
                for (position, value) in tuple.conditions.enumerated() {
                    let key = TagValueKey(family: value.family, value: value.value)
                    index.slots[key, default: []].append(
                        Index.Slot(tag: tagSlot, rule: ruleSlot, position: position))
                    index.families.insert(value.family)
                }
            }
        }
        return index
    }

    /// Matching tags by index into `rows`, strongest first. A row with no match
    /// is absent from the map — every downstream reader treats "absent" as
    /// untagged, so an empty array would be a second spelling of the same fact.
    ///
    /// - Parameters:
    ///   - columns: the result's columns; only `dataType` is read, for the
    ///     family. Column NAMES take no part in matching.
    ///   - rows: the result's values as text. Every value crosses the FFI as a
    ///     string, so there is nothing else to compare.
    ///   - index: from `buildIndex`.
    static func match(columns: [ColumnDef], rows: [[String?]], index: Index)
        -> [Int: [TagRowMatch]] {
        guard !index.isEmpty else { return [:] }

        // One classification for the whole result. nil means "no tagged value
        // could ever live in this column", and that cell is never normalized —
        // the cheapest way to skip a wide result's uninteresting columns.
        let families: [String?] = columns.map {
            let family = TagValueNormalizer.family(forDataType: $0.dataType)
            return index.families.contains(family) ? family : nil
        }
        guard families.contains(where: { $0 != nil }) else { return [:] }

        var out: [Int: [TagRowMatch]] = [:]
        for (rowIndex, row) in rows.enumerated() {
            // Per row: which slots of which tuples were satisfied, which result
            // columns hit, and which tuples each tag heard from.
            var satisfied: [Int: Set<Int>] = [:]
            var matchedColumns: [Int: Set<Int>] = [:]
            var touched: [Int: Set<Int>] = [:]

            for (column, family) in families.enumerated() {
                guard let family, column < row.count,
                      let key = TagValueNormalizer.key(text: row[column], family: family),
                      let hits = index.slots[key]
                else { continue }
                // One probe returns EVERY slot holding this value, including two
                // slots of one tuple — which is exactly the design's rule that
                // presence, not multiplicity, satisfies a slot.
                for hit in hits {
                    satisfied[hit.rule, default: []].insert(hit.position)
                    matchedColumns[hit.tag, default: []].insert(column)
                    touched[hit.tag, default: []].insert(hit.rule)
                }
            }
            guard !touched.isEmpty else { continue }

            var matches: [TagRowMatch] = []
            for (tag, tuples) in touched {
                let complete = tuples
                    .filter { satisfied[$0]?.count == index.ruleWidth[$0] }
                    .map { index.ruleIds[$0] }
                    .sorted()
                matches.append(TagRowMatch(
                    tagId: index.tagIds[tag],
                    state: complete.isEmpty ? .dashed : .solid,
                    matchedColumns: matchedColumns[tag]?.sorted() ?? [],
                    matchedRuleIds: tuples.map { index.ruleIds[$0] }.sorted(),
                    solidRuleIds: complete))
            }
            out[rowIndex] = ordered(matches)
        }
        return out
    }

    /// Strongest first: solid before dashed, then more matched values, then the
    /// tag id.
    ///
    /// The id is the last key only so that two otherwise equal matches cannot
    /// swap places between runs of the same query. `touched` is a dictionary and
    /// its iteration order is not stable, so without a total ordering the bar
    /// colour of a two-tag row would change at random — the same reason
    /// `RowFingerprint` breaks its own ties on position.
    static func ordered(_ matches: [TagRowMatch]) -> [TagRowMatch] {
        matches.sorted { a, b in
            if a.state != b.state { return a.state == .solid }
            if a.matchedColumns.count != b.matchedColumns.count {
                return a.matchedColumns.count > b.matchedColumns.count
            }
            return a.tagId < b.tagId
        }
    }

    /// How many of `rows` any tuple of `tag` would match. The modal's live
    /// count, and deliberately the REAL matcher rather than a cheaper estimate
    /// — a count that disagreed with what saves would be worse than no count.
    static func matchCount(tag: Tag, columns: [ColumnDef], rows: [[String?]]) -> Int {
        match(columns: columns, rows: rows, index: buildIndex([tag])).count
    }
}
