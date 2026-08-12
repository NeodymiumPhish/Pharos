// Standalone test runner for TagMatcher. Compiled with the implementation by
// scripts/test-tag-matcher.sh.
import Foundation

var failures = 0

func expectEqual(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectLabel(_ map: [Int: RowTag], _ row: Int, _ labelId: String?, _ name: String) {
    let actual = map[row]?.labelId
    if actual == labelId { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(String(describing: labelId))\n  actual:   \(String(describing: actual))")
    }
}

// MARK: - Fixtures

func tag(_ id: String, label: String, kind: String, value: String,
         tableKey: String = "oid:1", columns: [String] = ["id"]) -> RowTag {
    RowTag(id: id, connectionId: "c", labelId: label, note: nil,
           primaryKind: kind, tableKey: tableKey, tableDisplay: "t",
           identityColumns: columns, identityValues: [value],
           keys: [RowTagKey(identityKind: kind, identityValue: value)],
           createdAt: "", updatedAt: "")
}

/// Index a tag under every key it holds, exactly as TagStore does.
func store(_ tags: [RowTag]) -> [String: RowTag] {
    var out: [String: RowTag] = [:]
    for t in tags {
        for k in t.keys {
            out[TagMatcher.compositeKey(tableKey: t.tableKey, kind: k.identityKind, value: k.identityValue)] = t
        }
    }
    return out
}

func identity(_ candidates: [KeySet], tableKey: String = "oid:1",
              tableKeys: [String] = ["oid:1"]) -> RowIdentity {
    RowIdentity(tableKey: tableKey, tableDisplay: "t", tableKeys: tableKeys, candidates: candidates)
}

func runTests() {
    // MARK: The cheap exit

    // The common case: nothing is tagged. It must cost one dictionary check.
    let noTags = TagMatcher.match(
        identity: identity([KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])]),
        rowCount: 1, columns: [], rows: [], tagsByIdentity: [:])
    expectEqual(noTags.count, 0, "an empty store matches nothing")

    // MARK: One candidate

    let pk = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1", "V1:2", "V1:3"])
    let t1 = tag("t1", label: "red", kind: "pk", value: "V1:2")
    let oneCandidate = TagMatcher.match(
        identity: identity([pk]), rowCount: 3, columns: [], rows: [],
        tagsByIdentity: store([t1]))
    expectEqual(oneCandidate.count, 1, "one row matches on the primary key")
    expectLabel(oneCandidate, 1, "red", "the matching row is row 1, not row 2")
    expectLabel(oneCandidate, 0, nil, "row 0 stays untagged")

    // MARK: Cross-tier match — the reason the kind is in the key

    // A tag made through a primary key must be found again by a result that
    // carries only the unique key. Both keys are indexed, so the unique key hits.
    let strong = RowTag(id: "t2", connectionId: "c", labelId: "blue", note: nil,
                        primaryKind: "pk", tableKey: "oid:1", tableDisplay: "t",
                        identityColumns: ["id"], identityValues: ["1"],
                        keys: [RowTagKey(identityKind: "pk", identityValue: "V1:1"),
                               RowTagKey(identityKind: "unique", identityValue: "V6:a@b.co")],
                        createdAt: "", updatedAt: "")
    let uniqueOnly = KeySet(kind: "unique", keyColumns: ["email"], keys: ["V6:a@b.co"])
    let cross = TagMatcher.match(
        identity: identity([uniqueOnly]), rowCount: 1, columns: [], rows: [],
        tagsByIdentity: store([strong]))
    expectLabel(cross, 0, "blue", "a pk tag is found again through its unique key")

    // MARK: Candidate order

    // Strongest first. When both candidates would hit, the first wins.
    let pkA = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:9"])
    let uniqueB = KeySet(kind: "unique", keyColumns: ["email"], keys: ["V1:8"])
    let both = store([tag("tp", label: "frompk", kind: "pk", value: "V1:9"),
                      tag("tu", label: "fromunique", kind: "unique", value: "V1:8")])
    let ordered = TagMatcher.match(
        identity: identity([pkA, uniqueB]), rowCount: 1, columns: [], rows: [],
        tagsByIdentity: both)
    expectLabel(ordered, 0, "frompk", "the strongest candidate wins")

    // The second candidate is tried when the first gives no hit.
    let onlyUnique = store([tag("tu", label: "fromunique", kind: "unique", value: "V1:8")])
    let fallThrough = TagMatcher.match(
        identity: identity([pkA, uniqueB]), rowCount: 1, columns: [], rows: [],
        tagsByIdentity: onlyUnique)
    expectLabel(fallThrough, 0, "fromunique", "the second candidate is tried after a miss")

    // MARK: The empty-key sentinel — the most important assertion here

    // An outer join leaves a NULL key column, and the core writes "" for that row.
    // An empty key must NEVER match, or every keyless row would take one tag.
    let withHole = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1", "", "V1:3"])
    let emptyTag = store([tag("te", label: "ghost", kind: "pk", value: "")])
    let sentinel = TagMatcher.match(
        identity: identity([withHole]), rowCount: 3, columns: [], rows: [],
        tagsByIdentity: emptyTag)
    expectEqual(sentinel.count, 0, "an empty key matches nothing, even against an empty stored key")

    // A row with an empty key in one candidate can still match through the other.
    let holeA = KeySet(kind: "pk", keyColumns: ["id"], keys: [""])
    let holeB = KeySet(kind: "unique", keyColumns: ["email"], keys: ["V1:7"])
    let rescued = TagMatcher.match(
        identity: identity([holeA, holeB]), rowCount: 1, columns: [], rows: [],
        tagsByIdentity: store([tag("tr", label: "green", kind: "unique", value: "V1:7")]))
    expectLabel(rescued, 0, "green", "a hole in one candidate still matches through the other")

    // MARK: The table key is part of the match

    // The same key value under a different table must not match.
    let otherTable = store([tag("to", label: "wrong", kind: "pk", value: "V1:1", tableKey: "oid:999")])
    let scoped = TagMatcher.match(
        identity: identity([KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])]),
        rowCount: 1, columns: [], rows: [], tagsByIdentity: otherTable)
    expectEqual(scoped.count, 0, "a tag on another table does not match")

    // MARK: One key, several rows

    // A one-to-many join repeats the key. One tag highlights every such row.
    let repeated = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:5", "V1:5", "V1:6"])
    let many = TagMatcher.match(
        identity: identity([repeated]), rowCount: 3, columns: [], rows: [],
        tagsByIdentity: store([tag("tm", label: "amber", kind: "pk", value: "V1:5")]))
    expectEqual(many.count, 2, "one tag covers every row holding the key")
    expectLabel(many, 0, "amber", "the first repeated row is tagged")
    expectLabel(many, 1, "amber", "the second repeated row is tagged")

    // MARK: Short key arrays must not trap

    // A block whose keys are shorter than the row count is a core bug, but it
    // must degrade to "no tag", never crash.
    let short = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])
    let ragged = TagMatcher.match(
        identity: identity([short]), rowCount: 5, columns: [], rows: [],
        tagsByIdentity: store([tag("ts", label: "red", kind: "pk", value: "V1:1")]))
    expectEqual(ragged.count, 1, "a short key array tags only the rows it covers")

    // MARK: No identity block

    let none = TagMatcher.match(identity: nil, rowCount: 3, columns: [], rows: [],
                                tagsByIdentity: store([tag("tn", label: "red", kind: "pk", value: "V1:1")]))
    expectEqual(none.count, 0, "no identity block matches nothing in the strong path")

    if failures == 0 {
        print("\nAll TagMatcher tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
