import Foundation

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

    /// Matching tags for the rows in `range` (every row when nil), strongest
    /// first, keyed by the row's index FROM `range.lowerBound`: a page
    /// matched alone goes into a whole map through `appendingPage`. A row
    /// with no match is absent from the map — every downstream reader treats "absent" as
    /// untagged, so an empty array would be a second spelling of the same fact.
    ///
    /// - Parameters:
    ///   - columns: the result's columns; only `dataType` is read, for the
    ///     family. Column NAMES take no part in matching.
    ///   - rows: the result's values as text. Every value crosses the FFI as a
    ///     string, so there is nothing else to compare. A column past the
    ///     table's last one reads as NULL.
    ///   - range: the rows to match; nil for all of them.
    ///   - index: from `buildIndex`.
    static func match(columns: [ColumnDef], rows: ResultTable, range: Range<Int>? = nil, index: Index)
        -> [Int: [TagRowMatch]] {
        guard !index.isEmpty else { return [:] }
        let range = range ?? 0..<rows.rowCount

        // One classification for the whole result. nil means "no condition
        // could ever answer this column", and that cell is never normalized —
        // the cheapest way to skip a wide result's uninteresting columns.
        let columnFamilies = columns.map { TagValueNormalizer.family(forDataType: $0.dataType) }
        let wanted = index.families.union(index.patternFamilies)
        let families: [String?] = columnFamilies.map { wanted.contains($0) ? $0 : nil }

        // A JSON column is read a second way, value by value, and its own family
        // above still answers a rule captured from a whole document. Parsing is
        // the costly part, so it happens only when a rule could use a value, and
        // once per cell: `expand` and the row loop share the answer.
        let jsonColumns = wanted.isDisjoint(with: TagValueNormalizer.everyFamily)
            ? [] : columnFamilies.indices.filter { TagValueNormalizer.isJSONFamily(columnFamilies[$0]) }
        guard !jsonColumns.isEmpty || families.contains(where: { $0 != nil }) else { return [:] }

        // The preparation pass runs ONLY when a pattern exists. Without one this
        // takes the path it always has and allocates nothing new, so a user who
        // authors no condition cannot be regressed.
        let expanded = !index.patterns.isEmpty

        // Without a pattern only an exact hit can use a key, so a document keeps
        // those alone. Its other values would otherwise stay in memory for the
        // whole row walk.
        let jsonKeys: [[[TagValueKey]]] = jsonColumns.isEmpty ? [] : range.map { row in
            jsonColumns.map { column in
                let keys = TagValueNormalizer.jsonLeafKeys(text: rows.string(row, column), families: wanted)
                return expanded ? keys : keys.filter { index.slots[$0] != nil }
            }
        }

        var cellKeys: [[TagValueKey?]] = []
        var overlay: [TagValueKey: [Index.Slot]] = [:]
        if expanded {
            (cellKeys, overlay) = expand(families: families, rows: rows, range: range, jsonKeys: jsonKeys,
                                         index: index)
        }

        var out: [Int: [TagRowMatch]] = [:]
        for (rowIndex, row) in range.enumerated() {
            // Per row: which slots of which tuples were satisfied, which result
            // columns hit, and which tuples each tag heard from.
            var satisfied: [Int: Set<Int>] = [:]
            var matchedColumns: [Int: Set<Int>] = [:]
            var touched: [Int: Set<Int>] = [:]

            // Two probes, both O(1). Each returns EVERY slot holding this
            // value — including two slots of one rule, which is the design's
            // rule that presence, not multiplicity, satisfies a slot.
            func probe(_ key: TagValueKey, column: Int) {
                if let hits = index.slots[key] {
                    record(hits, column: column, satisfied: &satisfied,
                           matchedColumns: &matchedColumns, touched: &touched)
                }
                if expanded, let hits = overlay[key] {
                    record(hits, column: column, satisfied: &satisfied,
                           matchedColumns: &matchedColumns, touched: &touched)
                }
            }

            for (column, family) in families.enumerated() {
                guard let family else { continue }
                let key: TagValueKey?
                if expanded {
                    // `cellKeys[rowIndex]` is always `families.count` wide, so
                    // a column past the table's last one is already handled —
                    // `expand` left its cells nil.
                    key = cellKeys[rowIndex][column]
                } else {
                    key = TagValueNormalizer.key(text: rows.string(row, column), family: family)
                }
                guard let key else { continue }
                probe(key, column: column)
            }
            for (position, column) in jsonColumns.enumerated() {
                for key in jsonKeys[rowIndex][position] {
                    probe(key, column: column)
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

    /// Should this result match off the main thread, whatever its row count?
    ///
    /// Row count measures the work of a result of ordinary cells, and a JSON cell
    /// is not one: it is parsed, and it can hold many megabytes. So the callers'
    /// row thresholds do not protect a short result of large documents.
    ///
    /// Stops counting at the limit, so its own cost has a small bound.
    /// `range` is the rows to look at; nil for all of them.
    static func holdsHeavyJSON(columns: [ColumnDef], rows: ResultTable, range: Range<Int>? = nil) -> Bool {
        let jsonColumns = columns.indices.filter {
            TagValueNormalizer.isJSONFamily(TagValueNormalizer.family(forDataType: columns[$0].dataType))
        }
        guard !jsonColumns.isEmpty else { return false }
        var bytes = 0
        for row in range ?? 0..<rows.rowCount {
            for column in jsonColumns {
                bytes += rows.utf8Count(row, column)
            }
            if bytes > heavyJSONBytes { return true }
        }
        return false
    }

    /// Measured on sample documents: reading this much takes about 1.5 ms for
    /// most rules, and about 60 ms for a date rule when one value in five is a
    /// timestamp, because each timestamp goes through `DateFormatter`.
    private static let heavyJSONBytes = 64 * 1024

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
    private static func expand(families: [String?], rows: ResultTable, range: Range<Int>,
                               jsonKeys: [[[TagValueKey]]], index: Index)
        -> (cellKeys: [[TagValueKey?]], overlay: [TagValueKey: [Index.Slot]]) {
        var cellKeys = [[TagValueKey?]](repeating: [], count: range.count)
        var distinct = Set<TagValueKey>()
        for (rowIndex, row) in range.enumerated() {
            var keys = [TagValueKey?](repeating: nil, count: families.count)
            for (column, family) in families.enumerated() {
                guard let family,
                      let key = TagValueNormalizer.key(text: rows.string(row, column), family: family)
                else { continue }
                keys[column] = key
                distinct.insert(key)
            }
            cellKeys[rowIndex] = keys
        }
        for rowKeys in jsonKeys {
            for keys in rowKeys { distinct.formUnion(keys) }
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

    /// How many of `rows` the tag claims, and how many it merely touches.
    ///
    /// Two numbers because they answer different questions and one of them was
    /// silently doing both jobs badly. `solid` is what the tag CLAIMS: one whole
    /// rule present. It falls when a rule tightens, which is what lets the
    /// modal's footer tell an analyst whether tightening helped — the previous
    /// single count included dashed rows, so an extra condition could only ever
    /// add to it.
    ///
    /// `partial` is what the tag TOUCHES without claiming. Those rows tint too,
    /// so an analyst who saw only `solid` would see more colour than the number
    /// accounted for.
    ///
    /// Deliberately the REAL matcher rather than a cheaper estimate — a count
    /// that disagreed with what saves would be worse than no count.
    static func matchCounts(tag: Tag, columns: [ColumnDef], rows: ResultTable)
        -> (solid: Int, partial: Int) {
        let matches = match(columns: columns, rows: rows, index: buildIndex([tag]))
        var solid = 0
        var partial = 0
        for rowMatches in matches.values {
            // `buildIndex([tag])` indexes exactly one tag, so each row's match
            // list holds at most one verdict for it — `first` is exhaustive,
            // not a narrowing choice among several.
            guard let state = rowMatches.first?.state else { continue }
            if state == .solid { solid += 1 } else { partial += 1 }
        }
        return (solid, partial)
    }

    /// The map of a result that grew by a page: `existing` for its first rows,
    /// plus `page` (matched on the new rows alone) moved down by `offset`, the
    /// row count before the page.
    ///
    /// Equal to matching every row again, because a row's verdict reads only
    /// that row: the pattern overlay in `expand` is a memo keyed by cell value,
    /// so the other rows in the call never change a row's result.
    /// `scripts/test-tag-incremental-match.sh` holds this for every condition
    /// kind and for JSON columns.
    static func appendingPage(_ page: [Int: [TagRowMatch]], to existing: [Int: [TagRowMatch]],
                              offset: Int) -> [Int: [TagRowMatch]] {
        var merged = existing
        merged.reserveCapacity(existing.count + page.count)
        for (row, matches) in page { merged[row + offset] = matches }
        return merged
    }
}
