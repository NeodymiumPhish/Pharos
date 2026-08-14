// Standalone test runner for TagInspectorModel. Pure Foundation, no AppKit.
// Compiled with the implementation by scripts/test-tag-inspector-model.sh.
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

private func col(_ name: String, _ type: String) -> ColumnDef {
    ColumnDef(name: name, dataType: type)
}

private func value(_ column: String, _ family: String, _ normalized: String,
                   display: String? = nil) -> TaggedValue {
    TaggedValue(column: column, family: family, value: normalized,
                display: display ?? normalized)
}

private func tuple(_ id: String, _ values: [TaggedValue]) -> TagTuple {
    TagTuple(id: id, values: values, tupleKey: "k-\(id)",
             originConnection: "conn", originTable: "public.t",
             createdAt: "2026-08-14T00:00:00Z")
}

private func tag(_ id: String, _ name: String, note: String? = nil, colorIndex: Int = 2,
                 tuples: [TagTuple]) -> Tag {
    Tag(id: id, name: name, colorIndex: colorIndex, note: note,
        createdAt: "2026-08-14T00:00:00Z", updatedAt: "2026-08-14T00:00:00Z",
        tuples: tuples)
}

private func match(_ tagId: String, _ state: TagMatchState,
                   matchedTupleIds: [String], solidTupleIds: [String]) -> TagRowMatch {
    TagRowMatch(tagId: tagId, state: state, matchedColumns: [0],
                matchedTupleIds: matchedTupleIds, solidTupleIds: solidTupleIds)
}

func runTests() {
    let columns = [col("md5", "text"), col("subject", "text"), col("port", "int4")]

    // MARK: - 1. A solid single-value match: the completed tuple, all values matched

    do {
        let t = tag("t1", "Suspect infra", note: "May sprint",
                    tuples: [tuple("u1", [value("md5", "text", "d41d8c")])])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .solid, matchedTupleIds: ["u1"], solidTupleIds: ["u1"])],
            tags: [t], columns: columns,
            rowText: ["d41d8c", "CN=x", "443"])
        expectEqual(entries.count, 1, "one match, one entry")
        expectEqual(entries.first?.tagId, "t1", "the entry carries the tag id")
        expectEqual(entries.first?.name, "Suspect infra", "the entry carries the tag name")
        expectEqual(entries.first?.colorIndex, 2, "the entry carries the tag's colour index")
        expectEqual(entries.first?.note, "May sprint", "the entry carries the note")
        expectEqual(entries.first?.isPartial, false, "a solid match is not partial")
        expectEqual(entries.first?.isCrossTuple, false, "a solid match never shows the cross-tuple line")
        expectEqual(entries.first?.values.count, 1, "the displayed tuple has one value")
        expectEqual(entries.first?.values.first?.isMatched, true, "the completed value is marked matched")
        expectEqual(entries.first?.values.first?.column, "md5", "provenance column name shown")
    }

    // MARK: - 2. Case drift still marks matched — presence uses normalized values

    do {
        let t = tag("t1", "Hashes",
                    tuples: [tuple("u1", [value("md5", "text", "d41d8c", display: "D41D8C")])])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .solid, matchedTupleIds: ["u1"], solidTupleIds: ["u1"])],
            tags: [t], columns: columns,
            rowText: ["D41D8C", nil, nil])   // upper-case in the row, lower-case stored
        expectEqual(entries.first?.values.first?.isMatched, true,
                    "an upper-case row value matches the stored normalized value")
        expectEqual(entries.first?.values.first?.display, "D41D8C",
                    "the captured display text is what the section shows")
    }

    // MARK: - 3. A dashed match: present and absent values marked apart

    do {
        let t = tag("t1", "Pairs", tuples: [
            tuple("u1", [value("ip", "text", "10.2.3.4"), value("subject", "text", "cn=other")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .dashed, matchedTupleIds: ["u1"], solidTupleIds: [])],
            tags: [t], columns: columns,
            rowText: ["10.2.3.4", "cn=different", nil])
        expectEqual(entries.first?.isPartial, true, "a dashed match is partial")
        expectEqual(entries.first?.values.map(\.isMatched), [true, false],
                    "the present value is marked, the absent one is not")
        expectEqual(entries.first?.isCrossTuple, false,
                    "one contributing tuple — no cross-tuple line")
    }

    // MARK: - 4. Cross-tuple dashed match sets the explanation flag

    do {
        let t = tag("t1", "Pairs", tuples: [
            tuple("u1", [value("ip", "text", "10.2.3.4"), value("subject", "text", "cn=a")]),
            tuple("u2", [value("ip", "text", "10.9.9.9"), value("subject", "text", "cn=b")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .dashed, matchedTupleIds: ["u1", "u2"], solidTupleIds: [])],
            tags: [t], columns: columns,
            rowText: ["10.2.3.4", "cn=b", nil])
        expectEqual(entries.first?.isCrossTuple, true,
                    "matched values from two tuples set the cross-tuple flag")
    }

    // MARK: - 5. The displayed tuple is the one with the MOST present values

    do {
        // Discriminating fixture: the tuple with more present values has the
        // LATER id, so an implementation that picks by id order fails here.
        let t = tag("t1", "Pairs", tuples: [
            tuple("a-first", [value("ip", "text", "10.2.3.4"), value("subject", "text", "cn=absent")]),
            tuple("z-last", [value("ip", "text", "10.2.3.4"), value("subject", "text", "cn=b")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .dashed, matchedTupleIds: ["a-first", "z-last"], solidTupleIds: [])],
            tags: [t], columns: columns,
            rowText: ["10.2.3.4", "cn=b", nil])
        expectEqual(entries.first?.values.map(\.isMatched), [true, true],
                    "the tuple with two present values is displayed, not the earlier-id tuple")
    }

    // MARK: - 6. On a present-count tie, the lower tuple id wins (stable)

    do {
        let t = tag("t1", "Pairs", tuples: [
            tuple("b", [value("subject", "text", "cn=absent-1"), value("ip", "text", "10.2.3.4")]),
            tuple("a", [value("subject", "text", "cn=absent-2"), value("ip", "text", "10.2.3.4")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .dashed, matchedTupleIds: ["b", "a"], solidTupleIds: [])],
            tags: [t], columns: columns,
            rowText: ["10.2.3.4", "cn=nothing", nil])
        expectEqual(entries.first?.values.first?.display, "cn=absent-2",
                    "the tie breaks to tuple id \"a\", the lower id")
    }

    // MARK: - 7. A solid match displays the FIRST solid tuple

    do {
        let t = tag("t1", "Hashes", tuples: [
            tuple("u1", [value("md5", "text", "d41d8c")]),
            tuple("u2", [value("md5", "text", "aaaaaa")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .solid, matchedTupleIds: ["u1", "u2"], solidTupleIds: ["u1", "u2"])],
            tags: [t], columns: columns,
            rowText: ["d41d8c", nil, nil])
        expectEqual(entries.first?.values.first?.display, "d41d8c",
                    "the first solid tuple is the displayed one")
        expectEqual(entries.first?.isCrossTuple, false,
                    "a SOLID match with two matched tuples still shows no cross-tuple line")
    }

    // MARK: - 8. Order follows the matches array; unknown tags are skipped

    do {
        let t1 = tag("t1", "First", colorIndex: 3, tuples: [tuple("u1", [value("md5", "text", "d41d8c")])])
        let t2 = tag("t2", "Second", colorIndex: 7, tuples: [tuple("u2", [value("md5", "text", "d41d8c")])])
        let entries = TagInspectorModel.entries(
            matches: [
                match("t2", .solid, matchedTupleIds: ["u2"], solidTupleIds: ["u2"]),
                match("ghost", .solid, matchedTupleIds: ["ux"], solidTupleIds: ["ux"]),
                match("t1", .dashed, matchedTupleIds: ["u1"], solidTupleIds: []),
            ],
            tags: [t1, t2], columns: columns,
            rowText: ["d41d8c", nil, nil])
        expectEqual(entries.map(\.name), ["Second", "First"],
                    "entries keep the matcher's order and drop the unknown tag id")
        expectEqual(entries.map(\.colorIndex), [7, 3],
                    "each entry carries its OWN tag's colour index, not a shared default")
    }

    // MARK: - 9. Notes: whitespace-only and empty become nil

    do {
        let t = tag("t1", "NoNote", note: "   ",
                    tuples: [tuple("u1", [value("md5", "text", "d41d8c")])])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .solid, matchedTupleIds: ["u1"], solidTupleIds: ["u1"])],
            tags: [t], columns: columns,
            rowText: ["d41d8c", nil, nil])
        expectEqual(entries.first?.note, nil, "a whitespace-only note displays as no note")
    }

    // MARK: - 10. No matches, no entries

    expectTrue(TagInspectorModel.entries(matches: [], tags: [], columns: columns,
                                         rowText: ["x", "y", "z"]).isEmpty,
               "an unmatched row has no entries")

    // MARK: - 11. Family takes part in the key: text does not match numeric

    do {
        let t = tag("t1", "Mismatch", tuples: [
            tuple("u1", [value("port", "text", "443")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .dashed, matchedTupleIds: ["u1"], solidTupleIds: [])],
            tags: [t], columns: columns,
            rowText: [nil, nil, "443"])
        expectEqual(entries.first?.values.first?.isMatched, false,
                    "a text-family value does not match a numeric column")
    }

    // MARK: - 12. The bounds guard: a column beyond the row's captured cells
    // is SKIPPED, not clamped onto another cell

    do {
        // The tag value belongs to "port" (numeric family). rowText holds ONE
        // text cell, "443". Skipping the out-of-range column gives no numeric
        // key, so the value cannot match. A clamp reading cell 0 under the
        // numeric family would wrongly mark it matched.
        let t = tag("t1", "ShortRow", tuples: [
            tuple("u1", [value("port", "numeric", "443")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .dashed, matchedTupleIds: ["u1"], solidTupleIds: [])],
            tags: [t], columns: columns,
            rowText: ["443"])   // only one cell captured; "subject" and "port" have none
        expectEqual(entries.first?.values.first?.isMatched, false,
                    "an out-of-range column is skipped, not clamped onto another cell")
    }

    // MARK: - 13. A solid match whose recorded tuple was deleted falls through

    do {
        let t = tag("t1", "Recovered", tuples: [
            // "u1" no longer exists; the fallback "u2" is itself only
            // partially present (its second value has no match in the row).
            tuple("u2", [value("md5", "text", "aaaaaa"), value("subject", "text", "absent")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .solid, matchedTupleIds: ["u1", "u2"], solidTupleIds: ["u1"])],
            tags: [t], columns: columns,
            rowText: ["aaaaaa", nil, nil])
        expectEqual(entries.count, 1,
                    "a solid match survives when its recorded tuple was deleted")
        expectEqual(entries.first?.values.first?.display, "aaaaaa",
                    "it falls through to the best remaining contributing tuple")
        expectEqual(entries.first?.isPartial, false,
                    "the state still comes from the matcher, not the fallback tuple")
        expectEqual(entries.first?.values.map(\.isMatched), [true, false],
                    "a fallback tuple can show an unmatched value inside a SOLID entry")
    }

    // MARK: - 14. A NULL cell never matches a tagged empty string

    do {
        let t = tag("t1", "EmptyValue", tuples: [
            tuple("u1", [value("subject", "text", "")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .dashed, matchedTupleIds: ["u1"], solidTupleIds: [])],
            tags: [t], columns: columns,
            rowText: [nil, nil, nil])
        expectEqual(entries.first?.values.first?.isMatched, false,
                    "a NULL cell never matches a tagged empty string")
    }

    // MARK: - 15. On a zero-present tie, the lower tuple id still wins

    do {
        let t = tag("t1", "NoneClose", tuples: [
            tuple("b", [value("subject", "text", "cn=nope-b")]),
            tuple("a", [value("subject", "text", "cn=nope-a")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .dashed, matchedTupleIds: ["b", "a"], solidTupleIds: [])],
            tags: [t], columns: columns,
            rowText: ["nothing-matches", "cn=totally-different", nil])
        expectEqual(entries.first?.values.first?.display, "cn=nope-a",
                    "a tie at zero present values still breaks to the lower tuple id")
    }

    // MARK: - 16. A solid match still prefers the FIRST solid tuple, not most-present

    do {
        // tuple "a" = {x}; tuple "b" = {x, y}; the row holds x AND y, so BOTH
        // are complete and BOTH are solid. First-solid gives "a". Most-present
        // gives "b" — this pins that the solid preference in `displayedTuple`
        // is checked BEFORE the most-present fallback, not folded into it.
        let t = tag("t1", "BothSolid", tuples: [
            tuple("a", [value("md5", "text", "x")]),
            tuple("b", [value("md5", "text", "x"), value("subject", "text", "y")]),
        ])
        let entries = TagInspectorModel.entries(
            matches: [match("t1", .solid, matchedTupleIds: ["a", "b"], solidTupleIds: ["a", "b"])],
            tags: [t], columns: columns, rowText: ["x", "y", nil])
        expectEqual(entries.first?.values.map(\.display), ["x"],
                    "a solid match shows the FIRST solid tuple, not the one with most present values")
    }

    if failures == 0 {
        print("\nAll TagInspectorModel tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
