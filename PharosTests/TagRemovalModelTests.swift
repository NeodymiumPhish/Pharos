// Standalone test runner for TagRemovalModel. Pure Foundation, no AppKit.
// Compiled with the implementation by scripts/test-tag-removal-model.sh.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

// MARK: - Fixtures

private func value(_ column: String, _ display: String) -> TaggedValue {
    TaggedValue(column: column, family: "text", value: display.lowercased(),
                display: display)
}

private func tuple(_ id: String, _ values: [TaggedValue]) -> TagTuple {
    TagTuple(id: id, values: values, tupleKey: "k-\(id)",
             originConnection: "conn", originTable: "public.t",
             createdAt: "2026-08-14T00:00:00Z")
}

private func tag(_ id: String, _ name: String, colorIndex: Int = 1, tuples: [TagTuple]) -> Tag {
    Tag(id: id, name: name, colorIndex: colorIndex, note: nil,
        createdAt: "2026-08-14T00:00:00Z", updatedAt: "2026-08-14T00:00:00Z",
        tuples: tuples)
}

// No default/derived fields: a helper that synthesises a field the code
// under test may read (a prior version defaulted `matchedTupleIds` from
// `solidTupleIds`) can hide a real bug behind coincidentally-equal fixtures.
// Every call site states both explicitly.
private func match(_ tagId: String, _ state: TagMatchState,
                    matchedTupleIds: [String], solidTupleIds: [String]) -> TagRowMatch {
    TagRowMatch(tagId: tagId, state: state, matchedColumns: [0],
                matchedTupleIds: matchedTupleIds, solidTupleIds: solidTupleIds)
}

func runTests() {
    let tagA = tag("tA", "Alpha", colorIndex: 1, tuples: [
        tuple("u1", [value("md5", "D41D8C")]),
        tuple("u2", [value("ip", "10.2.3.4"), value("subject", "CN=evil")]),
        tuple("u3", [value("md5", "AAAA")]),
        // Its display text embeds the separator `title` joins values with, so
        // this single-value tuple's title collides byte-for-byte with u2's —
        // see MARK 7.
        tuple("u4", [value("ip", "10.2.3.4  +  subject: CN=evil")]),
        // Reachable only via a corrupt `tuple_values` blob in production
        // (Rust decodes bad JSON to an empty list rather than failing the
        // load) — never via a live match. See MARK 8.
        tuple("e1", []),
    ])
    let tagB = tag("tB", "Beta", colorIndex: 2, tuples: [
        tuple("v1", [value("port", "443")]),
    ])

    // MARK: - 1. Groups span tags, follow the store's tag order, and dedupe

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [3, 7],
            matchesByRow: [
                3: [match("tB", .solid, matchedTupleIds: ["v1"], solidTupleIds: ["v1"]),
                    match("tA", .solid, matchedTupleIds: ["u1"], solidTupleIds: ["u1"])],
                7: [match("tA", .solid, matchedTupleIds: ["u1", "u2"], solidTupleIds: ["u1", "u2"])],   // u1 again
            ],
            tags: [tagA, tagB])
        expectEqual(groups.map(\.tagName), ["Alpha", "Beta"],
                    "groups follow the STORE's tag order, not the match order")
        expectEqual(groups[0].tuples.map(\.tupleId), ["u1", "u2"],
                    "duplicate tuple ids across rows collapse; order follows tag.tuples")
        expectEqual(groups[1].tuples.map(\.tupleId), ["v1"], "the second tag keeps its tuple")
        expectEqual(groups[0].colorIndex, 1, "a group carries ITS OWN tag's colour, not a fixed one")
        expectEqual(groups[1].colorIndex, 2, "a different tag carries a different colour")
        expectEqual(TagRemovalModel.footer(for: groups),
                    "Removes 3 tuples from 2 tags. The values stop matching in every result, on every connection — not only here.",
                    "footer(for:) derives its sentence from the SAME groups the sheet renders, so it cannot drift")
    }

    // MARK: - 2. Dashed matches contribute nothing

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [1],
            // Touched (matchedTupleIds) the ip half of u2 without completing
            // it (solidTupleIds empty) — a real dashed shape, not a stand-in.
            matchesByRow: [1: [match("tA", .dashed, matchedTupleIds: ["u2"], solidTupleIds: [])]],
            tags: [tagA])
        expectTrue(groups.isEmpty, "a dashed-only row completes no tuple, so there is nothing to list")
    }

    // MARK: - 3. Values arrive as structured tokens with their captured columns

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [0],
            matchesByRow: [0: [match("tA", .solid, matchedTupleIds: ["u1", "u2"], solidTupleIds: ["u1", "u2"])]],
            tags: [tagA])
        let tuples = groups[0].tuples
        expectEqual(tuples[0].values,
                    [TagRemovalValue(column: "md5", display: "D41D8C", normalized: "d41d8c")],
                    "a single-value tuple carries exactly one structured value")
        expectEqual(TagRemovalModel.valueText(for: tuples[0].values[0]).text, "md5: D41D8C",
                    "a value renders as column: display")
        expectEqual(tuples[1].values,
                    [TagRemovalValue(column: "ip", display: "10.2.3.4", normalized: "10.2.3.4"),
                     TagRemovalValue(column: "subject", display: "CN=evil", normalized: "cn=evil")],
                    "a multi-value tuple carries each value as its OWN structured element")
    }

    // MARK: - 4. Unknown tag ids and unknown tuple ids are skipped

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [0],
            matchesByRow: [0: [match("ghost", .solid, matchedTupleIds: ["zz"], solidTupleIds: ["zz"]),
                               match("tA", .solid, matchedTupleIds: ["u3", "gone"], solidTupleIds: ["u3", "gone"])]],
            tags: [tagA])
        expectEqual(groups.count, 1, "the unknown tag id contributes no group")
        expectEqual(groups[0].tuples.map(\.tupleId), ["u3"],
                    "an id the tag no longer holds is dropped, the rest survive")
    }

    // MARK: - 5. Rows with no matches contribute nothing

    expectTrue(TagRemovalModel.groups(targetRows: [9], matchesByRow: [:],
                                      tags: [tagA]).isEmpty,
               "an unmatched target row produces no groups")

    // MARK: - 6. The footer states reach in plain words, singular and plural

    expectEqual(TagRemovalModel.footer(tupleCount: 3, tagCount: 2),
                "Removes 3 tuples from 2 tags. The values stop matching in every result, on every connection — not only here.",
                "the plural footer")
    expectEqual(TagRemovalModel.footer(tupleCount: 1, tagCount: 1),
                "Removes 1 tuple from 1 tag. The values stop matching in every result, on every connection — not only here.",
                "the singular footer")
    expectEqual(TagRemovalModel.footer(tupleCount: 1, tagCount: 2),
                "Removes 1 tuple from 2 tags. The values stop matching in every result, on every connection — not only here.",
                "tuple count and tag count inflect INDEPENDENTLY: one tuple, many tags")
    expectEqual(TagRemovalModel.footer(tupleCount: 2, tagCount: 1),
                "Removes 2 tuples from 1 tag. The values stop matching in every result, on every connection — not only here.",
                "tuple count and tag count inflect INDEPENDENTLY: many tuples, one tag")

    // MARK: - 7. A value CONTAINING the separator still yields one element, not two

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [0],
            matchesByRow: [0: [match("tA", .solid, matchedTupleIds: ["u2", "u4"], solidTupleIds: ["u2", "u4"])]],
            tags: [tagA])
        let byId = Dictionary(uniqueKeysWithValues: groups[0].tuples.map { ($0.tupleId, $0) })
        // The collision the model must survive: joined into one line these two
        // tuples are byte-identical, and only their VALUES tell them apart.
        // Nothing in the model produces that joined form any more — this
        // builds it here, in the test, purely to prove the trap is real.
        let joined = { (t: TagRemovalTuple) in
            t.values.map { "\($0.column): \($0.display)" }.joined(separator: "  +  ")
        }
        expectEqual(joined(byId["u2"]!), joined(byId["u4"]!),
                    "a genuine 2-value tuple and a 1-value tuple whose display embeds the separator WOULD collide if joined")
        expectEqual(byId["u2"]!.values.count, 2, "the real multi-value tuple carries two structured values")
        expectEqual(byId["u4"]!.values.count, 1,
                    "a single value containing the separator text still yields exactly ONE structured value, not two")
        expectEqual(byId["u4"]!.values,
                    [TagRemovalValue(column: "ip", display: "10.2.3.4  +  subject: CN=evil",
                                     normalized: "10.2.3.4  +  subject: cn=evil")],
                    "the embedded separator is not re-parsed; the display string survives whole")
        expectEqual(byId["u2"]!.values.count > 1, true, "u2 goes as a whole: it has two values")
        expectEqual(byId["u4"]!.values.count > 1, false,
                    "u4 does NOT, even though joined it reads like u2 — values, not text, decide")
    }

    // MARK: - 8. A tuple with no captured values never reaches the sheet

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [0],
            matchesByRow: [0: [match("tA", .solid, matchedTupleIds: ["u1", "e1"], solidTupleIds: ["u1", "e1"])]],
            tags: [tagA])
        expectEqual(groups[0].tuples.map(\.tupleId), ["u1"],
                    "a tuple with an empty values array is filtered out — a blank row is the worst possible disclosure")
    }

    // MARK: - 9. targetRows is the CLICKED/SELECTED subset, not every row the result holds

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [3],
            matchesByRow: [
                3: [match("tA", .solid, matchedTupleIds: ["u1"], solidTupleIds: ["u1"])],
                // Row 4 has a real, solid match too — but it was never
                // selected. Walking `matchesByRow` instead of `targetRows`
                // would pull it in anyway, silently turning a per-row action
                // into a global one.
                4: [match("tB", .solid, matchedTupleIds: ["v1"], solidTupleIds: ["v1"])],
            ],
            tags: [tagA, tagB])
        expectEqual(groups.map(\.tagName), ["Alpha"],
                    "only the TARGET rows' matches contribute — an untargeted row's match must not leak in")
    }

    // MARK: - 10. solidTupleIds, not matchedTupleIds, decides what is removable

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [0],
            // The row touched all three of tA's tuples (matchedTupleIds) but
            // completed only u2 (solidTupleIds) — the shape a dashed-turned-
            // solid tag realistically produces on a wide row.
            matchesByRow: [0: [match("tA", .solid,
                                     matchedTupleIds: ["u1", "u2", "u3"],
                                     solidTupleIds: ["u2"])]],
            tags: [tagA])
        expectEqual(groups[0].tuples.map(\.tupleId), ["u2"],
                    "only the COMPLETE tuple is offered for removal, even though the row touched two others")
    }

    // MARK: - 11. A tag left with no live tuple contributes no group at all

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [0],
            // Both ids the row named are stale (the store no longer holds
            // either) — the tag must not render as an empty header.
            matchesByRow: [0: [match("tA", .solid,
                                     matchedTupleIds: ["gone1", "gone2"],
                                     solidTupleIds: ["gone1", "gone2"])]],
            tags: [tagA])
        expectTrue(groups.isEmpty, "a tag whose every named tuple is stale contributes NO group, not an empty one")
    }

    // MARK: - 12. checkedTupleIds: the commit's payload, in list order

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [0],
            matchesByRow: [0: [match("tA", .solid,
                                     matchedTupleIds: ["u1", "u2"],
                                     solidTupleIds: ["u1", "u2"]),
                               match("tB", .solid,
                                     matchedTupleIds: ["v1"],
                                     solidTupleIds: ["v1"])]],
            tags: [tagA, tagB])
        // Order matters and is the LIST's order: the sheet shows the tuples in
        // this sequence, and a payload in some other order cannot be read back
        // against what the analyst ticked.
        expectEqual(TagRemovalModel.checkedTupleIds(in: groups), ["u1", "u2", "v1"],
                    "the payload is every tuple of every group, in the order the sheet lists them")
        expectEqual(TagRemovalModel.checkedTupleIds(in: []), [],
                    "no groups means an empty payload, never a deletion")
        // The sheet hands in the CHECKED subset; the payload must follow it
        // down, not fall back to anything wider.
        let narrowed = [TagRemovalGroup(tagId: groups[0].tagId, tagName: groups[0].tagName,
                                        colorIndex: groups[0].colorIndex,
                                        tuples: [groups[0].tuples[1]])]
        expectEqual(TagRemovalModel.checkedTupleIds(in: narrowed), ["u2"],
                    "a narrowed group yields only the tuples it still holds")
    }

    // MARK: - 13. Escaping: what is read must be what would be deleted

    do {
        // The bidi override is the one that turns disclosure into a lie: raw,
        // this string DISPLAYS as "safe" followed by "exe.jpg" reversed out of
        // "gpj.exe", so the user reads one filename and deletes another.
        expectEqual(TagRemovalModel.escaped("safe\u{202E}gpj.exe"),
                    "safe<U+202E>gpj.exe",
                    "a right-to-left override is shown, not obeyed")
        expectEqual(TagRemovalModel.escaped("\u{200B}\u{200D}\u{FEFF}"),
                    "<U+200B><U+200D><U+FEFF>",
                    "zero-width characters cannot hide inside a value")
        expectEqual(TagRemovalModel.escaped("10.0.0\u{A0}.1"), "10.0.0<U+00A0>.1",
                    "a non-breaking space is not a space")
        expectEqual(TagRemovalModel.escaped("a\nb\tc"), "a<U+000A>b<U+0009>c",
                    "a newline cannot split one value into what reads as two")

        // Four values that otherwise render as four identical rows. The user
        // has to know WHICH box to untick, so no two may render alike.
        let lookalikes = ["10.0.0.1", "10.0.0.1\u{200B}", "10.0.0\u{A0}.1", "10.0.0.1 "]
            .map(TagRemovalModel.escaped)
        expectEqual(Set(lookalikes).count, 4,
                    "four look-alike values render four distinguishable ways")

        expectEqual(TagRemovalModel.escaped("10.0.0.1 "), "10.0.0.1<U+0020>",
                    "a trailing space is marked — at the end of a row it is invisible")
        expectEqual(TagRemovalModel.escaped(" 10.0.0.1"), "<U+0020>10.0.0.1",
                    "and so is a leading one")
        expectEqual(TagRemovalModel.escaped("CN=evil corp, O=x"), "CN=evil corp, O=x",
                    "an ordinary interior space is left alone — this is not a mangler")
        expectEqual(TagRemovalModel.escaped("café ☕ 日本"), "café ☕ 日本",
                    "ordinary non-ASCII text survives untouched")
    }

    // MARK: - 14. No value ever renders blank

    do {
        // Reachable: TagDraft fills `display` from the raw cell, and an empty
        // text cell is not NULL, so it passes the NULL guard and arrives as "".
        let empty = TagRemovalModel.valueText(
            for: TagRemovalValue(column: "ip", display: "", normalized: ""))
        expectEqual(empty.text, "ip: (empty)", "an empty display says so")
        expectEqual(empty.isPlaceholder, true, "and is marked as a placeholder, to be styled apart")

        // The count suffix arrived with `DisplayEscape`, which the result grid
        // now shares: PostgreSQL returns `character(n)` space-padded, and one
        // token per pad space mangles an ordinary grid cell. A RUN of the same
        // escaped scalar therefore carries its count. A single edge space is
        // still a bare `<U+0020>` — see the trailing-space case above.
        let spaces = TagRemovalModel.valueText(
            for: TagRemovalValue(column: "md5", display: "   ", normalized: ""))
        expectEqual(spaces.text, "md5: <U+0020\u{00D7}3>",
                    "whitespace is shown as what it is, and says how much of it there is")
        expectEqual(spaces.isPlaceholder, false,
                    "it is real captured data, so it is not styled as a stand-in")

        let nothing = TagRemovalModel.valueText(
            for: TagRemovalValue(column: "", display: "", normalized: ""))
        expectEqual(nothing.text, "(no column): (empty)",
                    "the worst case — a checkbox beside a bare colon — reads as words")
        expectEqual(nothing.isPlaceholder, true, "and is marked")

        let ordinary = TagRemovalModel.valueText(
            for: TagRemovalValue(column: "ip", display: "10.0.0.1", normalized: "10.0.0.1"))
        expectEqual(ordinary.isPlaceholder, false, "a real value is not a placeholder")
    }

    // MARK: - 15. The sheet discloses its REACH, not only what was captured

    do {
        // The whole point of the extra line. Every case here is one the sheet
        // used to understate: what it showed matched strictly more than it said.
        let reason = "matching compares this form, so other spellings can match too"

        expectEqual(
            TagRemovalModel.matchDisclosure(
                for: TagRemovalValue(column: "ip", display: "10.0.0.1", normalized: "10.0.0.1")),
            nil,
            "captured text that IS the matching form adds no second line — noise on every row would bury the ones that matter")

        expectEqual(
            TagRemovalModel.matchDisclosure(
                for: TagRemovalValue(column: "cc", display: "US", normalized: "us"))?.text,
            "matches as \u{201C}us\u{201D} — \(reason)",
            "a case-only difference is disclosed: the sheet used to say US while us was what stopped matching")

        // The char(20) case, and the reason `display` is not trimmed at
        // capture: eighteen pad spaces are part of what the cell held.
        let padded = TagRemovalValue(column: "cc", display: "US" + String(repeating: " ", count: 18),
                                     normalized: "us")
        expectEqual(TagRemovalModel.valueText(for: padded).text,
                    "cc: US<U+0020\u{00D7}18>",
                    "the captured text keeps its padding — that is the provenance")
        expectEqual(TagRemovalModel.matchDisclosure(for: padded)?.text,
                    "matches as \u{201C}us\u{201D} — \(reason)",
                    "and the reach beside it: a plain text cell holding `us` matches this tuple")
        expectEqual(TagRemovalModel.matchDisclosure(for: padded)?.isPlaceholder, false,
                    "a real matching form is not a stand-in")

        expectEqual(
            TagRemovalModel.matchDisclosure(
                for: TagRemovalValue(column: "amount", display: "0012.500", normalized: "12.5"))?.text,
            "matches as \u{201C}12.5\u{201D} — \(reason)",
            "a numeric canonicalisation is disclosed the same way, with no family-specific claim to get wrong")

        // The loudest thing this line can say, so it says it in words rather
        // than in a pair of empty quotes that would read as a rendering fault.
        let blank = TagRemovalValue(column: "note", display: "   ", normalized: "")
        expectEqual(TagRemovalModel.matchDisclosure(for: blank)?.text,
                    "matches as (empty) — \(reason)",
                    "an all-whitespace value matches every blank cell, and must not disclose that as nothing at all")
        expectEqual(TagRemovalModel.matchDisclosure(for: blank)?.isPlaceholder, true,
                    "the stand-in word is marked, so it can be styled apart from captured data")

        // The matching form is somebody else's data too: unescaped, a bidi
        // override in it would misrender exactly as it would in `display`.
        expectEqual(
            TagRemovalModel.matchDisclosure(
                for: TagRemovalValue(column: "f", display: "SAFE\u{202E}GPJ.EXE",
                                     normalized: "safe\u{202E}gpj.exe"))?.text,
            "matches as \u{201C}safe<U+202E>gpj.exe\u{201D} — \(reason)",
            "the matching form is escaped too — it can lie the same way the captured text could")

        // A tuple where only ONE value's reach differs: the other must stay
        // silent, or the signal is lost in the noise again.
        let mixed = TagRemovalTuple(tupleId: "u9", values: [
            TagRemovalValue(column: "ip", display: "10.0.0.1", normalized: "10.0.0.1"),
            TagRemovalValue(column: "cc", display: "US", normalized: "us"),
        ])
        expectEqual(mixed.values.map { TagRemovalModel.matchDisclosure(for: $0)?.text },
                    [nil, "matches as \u{201C}us\u{201D} — \(reason)"],
                    "in a multi-value tuple only the value whose reach differs gets a line")
    }

    if failures == 0 {
        print("\nAll TagRemovalModel tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
