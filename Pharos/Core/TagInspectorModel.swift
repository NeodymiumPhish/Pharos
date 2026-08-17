import Foundation

// MARK: - TagInspectorModel

/// One captured value of the displayed tuple, ready for the Inspector.
struct TagInspectorValue: Equatable {
    /// The captured column name — provenance, never used for matching.
    let column: String
    /// The value as captured.
    let display: String
    /// The normalized form matching actually compares. Kept beside `display`
    /// rather than replacing it: the captured text and its column are the
    /// provenance, this is the reach.
    let normalized: String
    /// True when the selected row holds this (family, normalized value).
    let isMatched: Bool

    /// The extra line disclosing the reach, or nil when the captured text IS
    /// the form matching compares.
    ///
    /// Already escaped, unlike `column` and `display`, which this section's
    /// view escapes as it draws them. The wording belongs to the model — the
    /// removal sheet must not describe the same value differently — and the
    /// escaping travels with the wording because the matching form is
    /// somebody else's data too.
    var matchDisclosure: TagMatchDisclosure.Line? {
        TagMatchDisclosure.line(display: display, normalized: normalized)
    }
}

/// One matching tag's Inspector entry.
struct TagInspectorEntry: Equatable {
    let tagId: String
    let name: String
    let colorIndex: Int
    /// nil when the tag has no note (empty and whitespace-only count as none).
    let note: String?
    /// dashed = partial.
    let isPartial: Bool
    /// The displayed tuple's values, in captured order.
    let values: [TagInspectorValue]
    /// Partial AND more than one tuple CONTRIBUTED a matched value — the
    /// "values matched from different tagged rows" explanation line. This is
    /// weaker than "the displayed values came from different tuples": with
    /// tuple A = {x, y} and tuple B = {x, z}, a row holding only x already
    /// makes both tuples contributors, even though a single value matched.
    let isCrossTuple: Bool

    /// The one word shown beside the tag name. It mirrors the bar's two
    /// styles, so the Inspector and the grid never name a state differently.
    var stateWord: String { isPartial ? "dashed" : "solid" }
}

/// Pure builder for the Inspector's Tags section. No AppKit, no store —
/// everything arrives as parameters so a standalone harness can pin it.
enum TagInspectorModel {

    /// The whole-tag delete confirmation. One producer serves both surfaces
    /// that offer the action — the Inspector's per-tag "Remove Tag…" and the
    /// manage sheet's "Delete Tag…" — so the two can never drift apart, and
    /// the wording is pinned by the standalone suite instead of by eye.
    ///
    /// Both the noun AND the verb inflect. Inflecting only the noun reads
    /// "Its 1 tuple stop matching", which is why this is a function and not
    /// an interpolated string at each call site.
    static func deleteConfirmation(
        name: String, tupleCount: Int
    ) -> (title: String, body: String) {
        let subject = tupleCount == 1
            ? "Its 1 tuple stops"
            : "Its \(tupleCount) tuples stop"
        return (
            title: "Delete tag \u{201C}\(name)\u{201D}?",
            body: "\(subject) matching in every result, on every connection — not only here."
        )
    }

    /// Entries in the matcher's order (strongest first). A match is skipped
    /// when its tag id is unknown (a delete landing mid-repaint) or when
    /// `displayedTuple` finds nothing to show — every tuple it could point to
    /// was itself deleted, or the tag now holds no tuples at all.
    static func entries(
        matches: [TagRowMatch],
        tags: [Tag],
        columns: [ColumnDef],
        rowText: [String?]
    ) -> [TagInspectorEntry] {
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: a duplicate tag id
        // would TRAP the app, and these ids come from the database — the same
        // reasoning as `TagPalette.bake`'s `colors`/`names` dictionaries.
        let tagById = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let present = presentKeys(columns: columns, rowText: rowText)

        return matches.compactMap { match in
            guard let tag = tagById[match.tagId] else { return nil }
            guard let tuple = displayedTuple(for: match, in: tag, present: present) else { return nil }

            let values = tuple.values.map { value in
                TagInspectorValue(
                    column: value.column,
                    display: value.display,
                    normalized: value.value,
                    isMatched: present.contains(
                        TagValueKey(family: value.family, value: value.value)))
            }
            let trimmedNote = tag.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            return TagInspectorEntry(
                tagId: tag.id,
                name: tag.name,
                colorIndex: tag.colorIndex,
                note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote,
                isPartial: match.state == .dashed,
                values: values,
                isCrossTuple: match.state == .dashed && match.matchedTupleIds.count > 1)
        }
    }

    /// The tuple to show for one tag's match: for a solid match, the first
    /// tuple in `solidTupleIds` (already sorted) — UNLESS that tuple was
    /// deleted since the match was computed, in which case this falls through
    /// to the same rule a dashed match uses. Without the fallthrough, a tuple
    /// deletion would make the Inspector entry vanish while the grid's bar —
    /// which drops a match on tag id only, not tuple id — still shows the tag,
    /// and the two would disagree about whether the row is tagged at all.
    ///
    /// The fallback is the contributing tuple with the most PRESENT values,
    /// ties broken by the lower tuple id — the best available explanation of
    /// what almost matched.
    ///
    /// The fallback answers "closest", not "complete", so it can hand a SOLID
    /// match (`isPartial` still comes from `match.state`, never recomputed
    /// here) a tuple that is itself only partially present: the entry's
    /// `values` can then mark one value matched and another absent even
    /// though the header reads "solid". That is the intended trade against
    /// the entry vanishing, and Task 6 must render it — a dash mark can sit
    /// beside a nominally solid tag.
    private static func displayedTuple(
        for match: TagRowMatch, in tag: Tag, present: Set<TagValueKey>
    ) -> TagTuple? {
        let tupleById = Dictionary(tag.tuples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let solidId = match.solidTupleIds.first, let solid = tupleById[solidId] {
            return solid
        }
        return match.matchedTupleIds
            .compactMap { tupleById[$0] }
            .max { a, b in
                let (ma, mb) = (presentCount(a, in: present), presentCount(b, in: present))
                // areInIncreasingOrder: on a tie the LOWER id must be
                // the "maximum", so the higher id compares as smaller.
                return ma == mb ? a.id > b.id : ma < mb
            }
    }

    private static func presentCount(_ tuple: TagTuple, in present: Set<TagValueKey>) -> Int {
        tuple.values.filter {
            present.contains(TagValueKey(family: $0.family, value: $0.value))
        }.count
    }

    /// Every (family, normalized value) the row holds — the matcher's probe
    /// key, rebuilt for one row. NULL cells contribute nothing, exactly as in
    /// `TagTupleMatcher`; a captured tagged value can itself be an empty
    /// string (capture drops NULL but keeps an empty text cell), so a NULL row
    /// cell must never be coerced into `""` here or it would falsely match one.
    private static func presentKeys(
        columns: [ColumnDef], rowText: [String?]
    ) -> Set<TagValueKey> {
        var keys = Set<TagValueKey>()
        for (index, column) in columns.enumerated() where index < rowText.count {
            let family = TagValueNormalizer.family(forDataType: column.dataType)
            if let key = TagValueNormalizer.key(text: rowText[index], family: family) {
                keys.insert(key)
            }
        }
        return keys
    }
}
