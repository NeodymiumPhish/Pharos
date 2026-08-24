import Foundation

// MARK: - TagDraft

/// Turns a selection plus a column choice into the tuples a tag will hold.
///
/// The creation mirror of `TagRuleMatcher`: the same normalizer, the same key
/// encoder, the same NULL rule. It is pure so that the modal's live count and
/// the tag that eventually saves are computed from ONE description of what a
/// tuple is — a count that disagreed with the saved tag would be worse than no
/// count at all.
enum TagDraft {

    /// One tuple per selected row, holding that row's values in the checked
    /// columns.
    ///
    /// NOT a cross product: ten rows and two columns give ten 2-value tuples,
    /// because the tuple IS the row's finding. A cross product would invent
    /// pairs no observation ever showed, and every one of them would match
    /// solid.
    ///
    /// - Parameters:
    ///   - selectedRows: the selected rows' values as text, in column order.
    ///   - columns: the result's columns, for names and families.
    ///   - checkedColumns: indices into `columns`.
    static func tuples(
        selectedRows: [[String?]],
        columns: [ColumnDef],
        checkedColumns: [Int],
        originConnection: String,
        originTable: String
    ) -> [NewTagRule] {
        guard !checkedColumns.isEmpty else { return [] }
        // One family lookup per checked column, not per row.
        let checked: [(index: Int, name: String, family: String)] = checkedColumns.compactMap {
            // A column index the result no longer holds is skipped rather than
            // trapping: the modal's list and the grid could disagree after a
            // Load More that changed the result's shape.
            guard $0 >= 0, $0 < columns.count else { return nil }
            return ($0, columns[$0].name,
                    TagValueNormalizer.family(forDataType: columns[$0].dataType))
        }
        guard !checked.isEmpty else { return [] }

        var out: [NewTagRule] = []
        var seen = Set<String>()
        for row in selectedRows {
            var values: [TagCondition] = []
            for column in checked {
                // A NULL is the ABSENCE of a value, not a value: it drops out of
                // the tuple instead of becoming a slot nothing can satisfy.
                guard column.index < row.count, let text = row[column.index] else { continue }
                values.append(TagCondition(
                    column: column.name,
                    family: column.family,
                    value: TagValueNormalizer.normalize(text, family: column.family),
                    display: text))
            }
            // A tuple that lost every value contributes nothing — an empty
            // tuple would be inert in the matcher and noise in the store.
            guard let key = RuleKey.encode(
                values.map { TagValueKey(family: $0.family, value: $0.value) })
            else { continue }
            // Two rows whose captured values normalize the same ARE one finding.
            // The unique index would absorb the repeat on write; collapsing here
            // keeps the live count honest about what saves.
            guard seen.insert(key).inserted else { continue }
            out.append(NewTagRule(conditions: values, tupleKey: key,
                                   originConnection: originConnection,
                                   originTable: originTable))
        }
        return out
    }

    /// A throwaway `Tag` around draft tuples, so the live count can run the real
    /// matcher. The ids never reach SQLite.
    static func previewTag(tuples: [NewTagRule]) -> Tag {
        Tag(id: "draft", name: "draft", colorIndex: 0, note: nil,
            createdAt: "", updatedAt: "",
            rules: tuples.enumerated().map { index, tuple in
                TagRule(id: "draft-\(index)", conditions: tuple.conditions,
                         tupleKey: tuple.tupleKey,
                         originConnection: tuple.originConnection,
                         originTable: tuple.originTable, createdAt: "")
            })
    }

    /// The design's breadth warning: above a tenth of the loaded rows, say so.
    /// It never blocks — a deliberately broad temporary tag is a legitimate
    /// tool, and the analyst is the one who knows.
    static func isBroad(matched: Int, loaded: Int) -> Bool {
        loaded > 0 && Double(matched) > Double(loaded) * 0.1
    }
}
