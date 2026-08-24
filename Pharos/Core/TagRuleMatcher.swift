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

        /// A condition a hash cannot answer, paired with the slot it fills.
        fileprivate struct PatternSlot {
            let predicate: TagPredicate
            let slot: Slot
        }
        fileprivate var patterns: [PatternSlot] = []
        /// Families any PATTERN could answer. `cidr` puts `text` in here as
        /// well as `address`.
        fileprivate var patternFamilies: Set<String> = []

        /// A tag made only of pattern conditions has an EMPTY `slots`, so
        /// testing `slots` alone would short-circuit `match` and let every
        /// pattern-only tag match nothing.
        var isEmpty: Bool { slots.isEmpty && patterns.isEmpty }
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

                // Compile BEFORE recording anything. A rule whose conditions
                // cannot all be evaluated is skipped WHOLE: recording only the
                // ones that compiled would leave a NARROWER rule than the
                // analyst wrote, and a narrower rule is easier to satisfy — a
                // false match, the one failure direction this model cannot
                // tolerate.
                var compiled: [TagPredicate?] = []
                compiled.reserveCapacity(tuple.conditions.count)
                var evaluable = true
                for condition in tuple.conditions {
                    if condition.kind == .exact {
                        compiled.append(nil)
                        continue
                    }
                    guard let predicate = TagPredicate.compile(condition) else {
                        evaluable = false
                        break
                    }
                    compiled.append(predicate)
                }
                guard evaluable else { continue }

                let ruleSlot = index.ruleIds.count
                index.ruleIds.append(tuple.id)
                index.ruleWidth.append(tuple.conditions.count)

                for (position, condition) in tuple.conditions.enumerated() {
                    let slot = Index.Slot(tag: tagSlot, rule: ruleSlot, position: position)
                    if let predicate = compiled[position] {
                        index.patterns.append(Index.PatternSlot(predicate: predicate, slot: slot))
                        for family in TagValueNormalizer.everyFamily
                        where predicate.tests(family: family) {
                            index.patternFamilies.insert(family)
                        }
                    } else {
                        let key = TagValueKey(family: condition.family, value: condition.value)
                        index.slots[key, default: []].append(slot)
                        index.families.insert(condition.family)
                    }
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

        // One classification for the whole result. nil means "no condition
        // could ever answer this column", and that cell is never normalized —
        // the cheapest way to skip a wide result's uninteresting columns.
        let families: [String?] = columns.map {
            let family = TagValueNormalizer.family(forDataType: $0.dataType)
            return index.families.contains(family) || index.patternFamilies.contains(family)
                ? family : nil
        }
        guard families.contains(where: { $0 != nil }) else { return [:] }

        // The preparation pass runs ONLY when a pattern exists. Without one this
        // takes the path it always has and allocates nothing new, so a user who
        // authors no condition cannot be regressed.
        let expanded = !index.patterns.isEmpty
        var cellKeys: [[TagValueKey?]] = []
        var overlay: [TagValueKey: [Index.Slot]] = [:]
        if expanded {
            (cellKeys, overlay) = expand(families: families, rows: rows, index: index)
        }

        var out: [Int: [TagRowMatch]] = [:]
        for (rowIndex, row) in rows.enumerated() {
            // Per row: which slots of which tuples were satisfied, which result
            // columns hit, and which tuples each tag heard from.
            var satisfied: [Int: Set<Int>] = [:]
            var matchedColumns: [Int: Set<Int>] = [:]
            var touched: [Int: Set<Int>] = [:]

            for (column, family) in families.enumerated() {
                guard let family else { continue }
                let key: TagValueKey?
                if expanded {
                    // `cellKeys[rowIndex]` is always `families.count` wide, so
                    // a short row is already handled — `expand` left its
                    // missing cells nil.
                    key = cellKeys[rowIndex][column]
                } else {
                    guard column < row.count else { continue }
                    key = TagValueNormalizer.key(text: row[column], family: family)
                }
                guard let key else { continue }
                // Two probes, both O(1). Each returns EVERY slot holding this
                // value — including two slots of one rule, which is the design's
                // rule that presence, not multiplicity, satisfies a slot.
                if let hits = index.slots[key] {
                    record(hits, column: column, satisfied: &satisfied,
                           matchedColumns: &matchedColumns, touched: &touched)
                }
                if expanded, let hits = overlay[key] {
                    record(hits, column: column, satisfied: &satisfied,
                           matchedColumns: &matchedColumns, touched: &touched)
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

    /// Fold one probe's hits into the row's tallies.
    ///
    /// Extracted so the exact and overlay probes cannot drift apart, and so
    /// neither has to build a merged array per cell just to share a loop.
    private static func record(
        _ hits: [Index.Slot], column: Int,
        satisfied: inout [Int: Set<Int>],
        matchedColumns: inout [Int: Set<Int>],
        touched: inout [Int: Set<Int>]
    ) {
        for hit in hits {
            satisfied[hit.rule, default: []].insert(hit.position)
            matchedColumns[hit.tag, default: []].insert(column)
            touched[hit.tag, default: []].insert(hit.rule)
        }
    }

    /// Expand every pattern against the result's DISTINCT values, once.
    ///
    /// This is what keeps the row loop a hash probe. Testing a pattern per CELL
    /// would cost `cells x patterns`; testing it per distinct value costs
    /// `distinct x patterns`, and the modal re-runs this whole matcher on every
    /// checkbox click, so that saving is paid back on every keystroke.
    ///
    /// Normalizing each distinct text once instead of each cell is the second
    /// saving: the cache this builds is what the row loop reads.
    private static func expand(families: [String?], rows: [[String?]], index: Index)
        -> (cellKeys: [[TagValueKey?]], overlay: [TagValueKey: [Index.Slot]]) {
        var cellKeys = [[TagValueKey?]](repeating: [], count: rows.count)
        var distinct = Set<TagValueKey>()
        for (rowIndex, row) in rows.enumerated() {
            var keys = [TagValueKey?](repeating: nil, count: families.count)
            for (column, family) in families.enumerated() {
                guard let family, column < row.count,
                      let key = TagValueNormalizer.key(text: row[column], family: family)
                else { continue }
                keys[column] = key
                distinct.insert(key)
            }
            cellKeys[rowIndex] = keys
        }

        var overlay: [TagValueKey: [Index.Slot]] = [:]
        for pattern in index.patterns {
            for key in distinct where pattern.predicate.tests(family: key.family) {
                guard pattern.predicate.matches(normalized: key.value, family: key.family)
                else { continue }
                overlay[key, default: []].append(pattern.slot)
            }
        }
        return (cellKeys, overlay)
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
