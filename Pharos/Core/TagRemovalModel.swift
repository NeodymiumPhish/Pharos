import Foundation

// MARK: - TagRemovalModel

/// One captured value inside a tuple the removal sheet lists, kept structured
/// beside `TagRemovalTuple.title` so the view renders one token per value.
/// `title` joins values with "  +  ", a separator a captured display string
/// can legally contain — two structurally different tuples can produce a
/// byte-identical joined title. Only `values` can tell them apart, which is
/// why the view must render from it rather than parsing `title`.
struct TagRemovalValue: Equatable {
    let column: String
    let display: String
}

/// One tuple the removal sheet offers for deletion.
struct TagRemovalTuple: Equatable {
    let tupleId: String
    /// "md5: D41D8C" or "ip: 10.2.3.4  +  subject: CN=evil" — disclosure text
    /// only. Captured column names as provenance, captured display text as
    /// the value. Do not parse this back into values; read `values` instead.
    let title: String
    /// The same values `title` joins, kept as structured, un-mergeable
    /// tokens — see the type's doc comment for why `title` alone is not
    /// enough to identify a tuple.
    let values: [TagRemovalValue]
    /// A multi-value tuple is removed or kept WHOLE: un-picking one value
    /// would leave a tuple that matches MORE rows than before, not fewer.
    let isMultiValue: Bool
}

/// One tag's block in the removal sheet.
struct TagRemovalGroup: Equatable {
    let tagId: String
    let tagName: String
    let colorIndex: Int
    let tuples: [TagRemovalTuple]
}

/// Pure builder for the removal confirmation sheet. Solid tuples only — a
/// dashed row holds fragments of several tuples and completes none of them,
/// so there is no tuple it can name for deletion (Phase 4's rule, unchanged).
enum TagRemovalModel {

    /// Every tuple the TARGET rows complete, deduplicated, grouped by tag in
    /// the STORE's tag order, tuples in each tag's own tuple order.
    ///
    /// `targetRows` is the clicked or selected subset, not every row the
    /// result holds — matching against the wrong set would silently widen a
    /// per-row action into a global one, exactly the defect this sheet
    /// exists to correct. Ids the store no longer holds (a concurrent
    /// delete) are dropped silently, and a tag left with no live tuple
    /// contributes no group at all — an empty header would still be counted
    /// by the footer. An empty result means the caller must not present the
    /// sheet: `footer(for: [])` reads as "Removes 0 tuples from 0 tags",
    /// which is not a sentence worth showing.
    static func groups(
        targetRows: [Int],
        matchesByRow: [Int: [TagRowMatch]],
        tags: [Tag]
    ) -> [TagRemovalGroup] {
        var idsByTag: [String: Set<String>] = [:]
        for row in targetRows {
            for match in matchesByRow[row] ?? [] where !match.solidTupleIds.isEmpty {
                idsByTag[match.tagId, default: []].formUnion(match.solidTupleIds)
            }
        }
        guard !idsByTag.isEmpty else { return [] }

        return tags.compactMap { tag in
            guard let ids = idsByTag[tag.id] else { return nil }
            let tuples = tag.tuples
                // `!$0.values.isEmpty`: a tuple with no captured values can
                // reach here from a corrupt `tuple_values` blob — Rust's CRUD
                // decodes bad JSON to an empty list rather than failing the
                // load (see `TagTupleMatcher.buildIndex`). A blank row on a
                // delete confirmation is the worst possible disclosure.
                .filter { ids.contains($0.id) && !$0.values.isEmpty }
                .map { tuple -> TagRemovalTuple in
                    let values = tuple.values.map {
                        TagRemovalValue(column: $0.column, display: $0.display)
                    }
                    let title = tuple.values
                        .map { "\($0.column): \($0.display)" }
                        .joined(separator: "  +  ")
                    return TagRemovalTuple(
                        tupleId: tuple.id, title: title, values: values,
                        isMultiValue: tuple.values.count > 1)
                }
            guard !tuples.isEmpty else { return nil }
            return TagRemovalGroup(
                tagId: tag.id, tagName: tag.name,
                colorIndex: tag.colorIndex, tuples: tuples)
        }
    }

    /// The footer, in plain words: how many tuples, from how many tags, and
    /// that the values stop matching everywhere rather than only here. Pure
    /// arithmetic, kept for the inflection tests — real call sites should
    /// prefer `footer(for:)`, which cannot be given counts that disagree
    /// with the list the sheet renders above it.
    static func footer(tupleCount: Int, tagCount: Int) -> String {
        let tuples = "\(tupleCount) tuple\(tupleCount == 1 ? "" : "s")"
        let tags = "\(tagCount) tag\(tagCount == 1 ? "" : "s")"
        return "Removes \(tuples) from \(tags). The values stop matching in every result, on every connection — not only here."
    }

    /// The footer derived FROM the groups it describes, so the count can
    /// never drift from the list the sheet renders above it.
    static func footer(for groups: [TagRemovalGroup]) -> String {
        footer(tupleCount: groups.reduce(0) { $0 + $1.tuples.count },
               tagCount: groups.count)
    }
}
