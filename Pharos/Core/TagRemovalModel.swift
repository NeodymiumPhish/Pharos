import Foundation

// MARK: - TagRemovalModel

/// One captured value inside a tuple the removal sheet lists, kept as a
/// structured, un-mergeable token.
///
/// There is deliberately no joined-string form of a tuple anywhere in this
/// model. Any separator a join could use is a string a captured value may
/// legally contain, so two structurally different tuples could produce the
/// same joined line — and on a delete confirmation, one tuple that can
/// impersonate another is the whole game. Rendering goes through
/// `TagRemovalModel.valueText(for:)`, one token per value.
struct TagRemovalValue: Equatable {
    let column: String
    let display: String
}

/// One tuple the removal sheet offers for deletion.
///
/// No `isMultiValue` flag: whether a tuple goes as a whole is read from
/// `values.count` at the point of use. A stored flag can disagree with the
/// values it describes — a one-value tuple carrying the "removed together"
/// caption, say — and derived state that can lie about a deletion is worth
/// nothing.
struct TagRemovalTuple: Equatable {
    let tupleId: String
    let values: [TagRemovalValue]
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
                .map { tuple in
                    TagRemovalTuple(
                        tupleId: tuple.id,
                        values: tuple.values.map {
                            TagRemovalValue(column: $0.column, display: $0.display)
                        })
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

    /// One value as the sheet must show it: escaped, never blank.
    struct ValueText: Equatable {
        let text: String
        /// The value or its column had nothing printable, so `text` carries a
        /// stand-in word rather than captured data. The sheet styles it apart
        /// so a placeholder can never be mistaken for a value.
        let isPlaceholder: Bool
    }

    /// Scalars that must never reach a delete confirmation as themselves.
    ///
    /// This app captures hostile data by design — the values in a tag came out
    /// of somebody's dataset — and a removal is permanent and global. Three
    /// families, all of which have been measured rendering wrong:
    ///
    /// - **Bidi controls.** `host: safe\u{202E}gpj.exe` DISPLAYS as
    ///   `safe\u{202E}gpj.exe` reversed — the user reads one filename and
    ///   deletes another. This is the one that turns disclosure into a lie.
    /// - **Zero-width and unusual spaces.** `10.0.0.1`, `10.0.0.1\u{200B}`,
    ///   `10.0.0\u{A0}.1` and `10.0.0.1 ` otherwise render as four identical
    ///   rows, and the user cannot tell which checkbox to untick.
    /// - **C0 controls.** A newline inside one value would split it across
    ///   lines and read as two separate values.
    private static func mustEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F: return true          // C0 controls and DEL
        case 0x200E, 0x200F, 0x061C: return true     // LRM, RLM, ALM
        case 0x202A...0x202E: return true            // the embedding/override set
        case 0x2066...0x2069: return true            // the isolate set
        case 0x200B...0x200D, 0x2060, 0xFEFF: return true  // zero-width, BOM
        case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return true  // spaces
        default: return false
        }
    }

    /// Render text so that what is read is what would be deleted.
    ///
    /// Offending scalars become `<U+XXXX>`. Leading and trailing PLAIN spaces
    /// are marked too, though a space is legal mid-value: at the edge of a row
    /// it is invisible, and "which of these two rows has the trailing space?"
    /// is exactly the question a user must be able to answer before ticking a
    /// box.
    static func escaped(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var lead = 0
        while lead < scalars.count, scalars[lead] == " " { lead += 1 }
        var trail = scalars.count
        while trail > lead, scalars[trail - 1] == " " { trail -= 1 }

        var out = ""
        for (index, scalar) in scalars.enumerated() {
            if index < lead || index >= trail || mustEscape(scalar) {
                out += String(format: "<U+%04X>", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The line the sheet shows for one value: "ip: 10.0.0.1".
    ///
    /// An empty column or display gets a stand-in word. `TagDraft` fills
    /// `display` from the raw cell and an empty text cell is not NULL, so it
    /// passes the NULL guard and arrives here as "" — which would otherwise
    /// draw a checkbox beside a bare colon, or beside nothing at all. A blank
    /// row on a delete confirmation is the worst possible disclosure.
    static func valueText(for value: TagRemovalValue) -> ValueText {
        let column = escaped(value.column)
        let display = escaped(value.display)
        return ValueText(
            text: "\(column.isEmpty ? "(no column)" : column): "
                + "\(display.isEmpty ? "(empty)" : display)",
            isPlaceholder: column.isEmpty || display.isEmpty)
    }

    /// The ids a removal commits, taken from the SAME groups the footer counts
    /// and the sheet lists — so the payload sent to the store cannot name a
    /// tuple the user did not see ticked.
    ///
    /// Pure and here rather than inside the sheet for the reason
    /// `footer(for:)` is: the commit's payload is the one part of a
    /// destructive action a test must be able to read without a store, a
    /// Keychain or a window.
    static func checkedTupleIds(in groups: [TagRemovalGroup]) -> [String] {
        groups.flatMap { $0.tuples.map(\.tupleId) }
    }
}
