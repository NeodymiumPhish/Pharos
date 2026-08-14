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

    // MARK: - 3. Titles show values with their captured column names

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [0],
            matchesByRow: [0: [match("tA", .solid, matchedTupleIds: ["u1", "u2"], solidTupleIds: ["u1", "u2"])]],
            tags: [tagA])
        let tuples = groups[0].tuples
        expectEqual(tuples[0].title, "md5: D41D8C", "a single-value tuple titles as column: display")
        expectEqual(tuples[0].isMultiValue, false, "one value is not multi-value")
        expectEqual(tuples[0].values, [TagRemovalValue(column: "md5", display: "D41D8C")],
                    "a single-value tuple carries exactly one structured value")
        expectEqual(tuples[1].title, "ip: 10.2.3.4  +  subject: CN=evil",
                    "a multi-value tuple joins its values with the + separator")
        expectEqual(tuples[1].isMultiValue, true, "two values mark the tuple multi-value")
        expectEqual(tuples[1].values,
                    [TagRemovalValue(column: "ip", display: "10.2.3.4"),
                     TagRemovalValue(column: "subject", display: "CN=evil")],
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
        expectEqual(byId["u2"]!.title, byId["u4"]!.title,
                    "a genuine 2-value tuple and a 1-value tuple whose display embeds the separator DO collide on title text")
        expectEqual(byId["u2"]!.values.count, 2, "the real multi-value tuple carries two structured values")
        expectEqual(byId["u4"]!.values.count, 1,
                    "a single value containing the separator text still yields exactly ONE structured value, not two")
        expectEqual(byId["u4"]!.values, [TagRemovalValue(column: "ip", display: "10.2.3.4  +  subject: CN=evil")],
                    "the embedded separator is not re-parsed; the display string survives whole")
        expectEqual(byId["u2"]!.isMultiValue, true, "u2 is genuinely multi-value")
        expectEqual(byId["u4"]!.isMultiValue, false,
                    "u4 is NOT multi-value even though its title reads like u2's — values, not title, decides")
    }

    // MARK: - 8. A tuple with no captured values never reaches the sheet

    do {
        let groups = TagRemovalModel.groups(
            targetRows: [0],
            matchesByRow: [0: [match("tA", .solid, matchedTupleIds: ["u1", "e1"], solidTupleIds: ["u1", "e1"])]],
            tags: [tagA])
        expectEqual(groups[0].tuples.map(\.tupleId), ["u1"],
                    "a tuple with an empty values array is filtered out — a blank title is the worst possible disclosure")
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

    if failures == 0 {
        print("\nAll TagRemovalModel tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
