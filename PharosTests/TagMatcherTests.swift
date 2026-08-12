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

/// `n` rows with no cells. The strong path reads only the row COUNT — its keys are
/// precomputed — so empty cells say "the values do not matter here".
func blankRows(_ n: Int) -> [[String?]] { Array(repeating: [], count: n) }

func runTests() {
    // MARK: The cheap exit

    // The common case: nothing is tagged. This is a smoke check on the guard, not
    // a measured fast path.
    let noTags = TagMatcher.match(
        identity: identity([KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])]),
        columns: [], rows: blankRows(1), tagsByIdentity: [:])
    expectEqual(noTags.count, 0, "an empty store matches nothing")

    // MARK: One candidate

    let pk = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1", "V1:2", "V1:3"])
    let t1 = tag("t1", label: "red", kind: "pk", value: "V1:2")
    let oneCandidate = TagMatcher.match(
        identity: identity([pk]), columns: [], rows: blankRows(3),
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
        identity: identity([uniqueOnly]), columns: [], rows: blankRows(1),
        tagsByIdentity: store([strong]))
    expectLabel(cross, 0, "blue", "a pk tag is found again through its unique key")

    // MARK: Candidate order

    // Strongest first. When both candidates would hit, the first wins.
    let pkA = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:9"])
    let uniqueB = KeySet(kind: "unique", keyColumns: ["email"], keys: ["V1:8"])
    let both = store([tag("tp", label: "frompk", kind: "pk", value: "V1:9"),
                      tag("tu", label: "fromunique", kind: "unique", value: "V1:8")])
    let ordered = TagMatcher.match(
        identity: identity([pkA, uniqueB]), columns: [], rows: blankRows(1),
        tagsByIdentity: both)
    expectLabel(ordered, 0, "frompk", "the strongest candidate wins")

    // The second candidate is tried when the first gives no hit.
    let onlyUnique = store([tag("tu", label: "fromunique", kind: "unique", value: "V1:8")])
    let fallThrough = TagMatcher.match(
        identity: identity([pkA, uniqueB]), columns: [], rows: blankRows(1),
        tagsByIdentity: onlyUnique)
    expectLabel(fallThrough, 0, "fromunique", "the second candidate is tried after a miss")

    // MARK: The empty-key sentinel — the most important assertion here

    // An outer join leaves a NULL key column, and the core writes "" for that row.
    // An empty key must NEVER match, or every keyless row would take one tag.
    let withHole = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1", "", "V1:3"])
    let emptyTag = store([tag("te", label: "ghost", kind: "pk", value: "")])
    let sentinel = TagMatcher.match(
        identity: identity([withHole]), columns: [], rows: blankRows(3),
        tagsByIdentity: emptyTag)
    expectEqual(sentinel.count, 0, "an empty key matches nothing, even against an empty stored key")

    // A row with an empty key in one candidate can still match through the other.
    let holeA = KeySet(kind: "pk", keyColumns: ["id"], keys: [""])
    let holeB = KeySet(kind: "unique", keyColumns: ["email"], keys: ["V1:7"])
    let rescued = TagMatcher.match(
        identity: identity([holeA, holeB]), columns: [], rows: blankRows(1),
        tagsByIdentity: store([tag("tr", label: "green", kind: "unique", value: "V1:7")]))
    expectLabel(rescued, 0, "green", "a hole in one candidate still matches through the other")

    // MARK: The table key is part of the match

    // The same key value under a different table must not match.
    let otherTable = store([tag("to", label: "wrong", kind: "pk", value: "V1:1", tableKey: "oid:999")])
    let scoped = TagMatcher.match(
        identity: identity([KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])]),
        columns: [], rows: blankRows(1), tagsByIdentity: otherTable)
    expectEqual(scoped.count, 0, "a tag on another table does not match")

    // The strong path must use `tableKey` (the primary table), NOT `tableKeys`.
    // Task 3's weak path uses `tableKeys` on purpose; a strong key belongs to one
    // table only, so a tag on another table in the result must not match.
    //
    // `tableKeys` lists the SECONDARY table first here, deliberately. That is what
    // makes the check discriminate: with `["oid:1", "oid:2"]` the first element
    // equals `tableKey`, so swapping `identity.tableKey` for
    // `identity.tableKeys.first` computes the same key and the test cannot tell the
    // two apart. Do not reorder this list. `tableKeys` carries no ordering
    // guarantee — it is every source table in the result — so a secondary-first
    // result is a real shape, not a contrivance.
    let secondaryTable = TagMatcher.match(
        identity: identity([KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])],
                           tableKey: "oid:1", tableKeys: ["oid:2", "oid:1"]),
        columns: [], rows: blankRows(1),
        tagsByIdentity: store([tag("t2t", label: "wrong", kind: "pk", value: "V1:1", tableKey: "oid:2")]))
    expectEqual(secondaryTable.count, 0, "a strong tag on a secondary table does not match")

    // MARK: The KIND is part of the match

    // Two tags on the same table can hold the SAME value string under different
    // kinds — a pk key and a fingerprint key are both just text, and nothing stops
    // them coinciding. The kind is in the index key so those are two entries.
    // Without it they collide, one silently replaces the other, and a strong result
    // then matches the wrong tag. The SQLite unique index holds the kind for this
    // same reason; leaving it out of the memory key would bring the collision back.
    let sameValue = store([
        tag("tk", label: "frompk", kind: "pk", value: "V1:1"),
        tag("tf", label: "fromfingerprint", kind: "fingerprint", value: "V1:1"),
    ])
    expectEqual(sameValue.count, 2, "two kinds with the same value are two index entries")
    let kindScoped = TagMatcher.match(
        identity: identity([KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])]),
        columns: [], rows: blankRows(1), tagsByIdentity: sameValue)
    expectLabel(kindScoped, 0, "frompk", "the pk key matches the pk tag, not the fingerprint tag")

    // MARK: One key, several rows

    // A one-to-many join repeats the key. One tag highlights every such row.
    let repeated = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:5", "V1:5", "V1:6"])
    let many = TagMatcher.match(
        identity: identity([repeated]), columns: [], rows: blankRows(3),
        tagsByIdentity: store([tag("tm", label: "amber", kind: "pk", value: "V1:5")]))
    expectEqual(many.count, 2, "one tag covers every row holding the key")
    expectLabel(many, 0, "amber", "the first repeated row is tagged")
    expectLabel(many, 1, "amber", "the second repeated row is tagged")

    // MARK: Short key arrays must not trap

    // A block whose keys are shorter than the row count is a core bug, but it
    // must degrade to "no tag", never crash.
    let short = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])
    let ragged = TagMatcher.match(
        identity: identity([short]), columns: [], rows: blankRows(5),
        tagsByIdentity: store([tag("ts", label: "red", kind: "pk", value: "V1:1")]))
    expectEqual(ragged.count, 1, "a short key array tags only the rows it covers")

    // The bounds guard must `continue`, not `break`: a candidate with a short key
    // array must not stop the row from trying the next candidate. This mirrors the
    // empty-key rescue check above.
    let raggedA = KeySet(kind: "pk", keyColumns: ["id"], keys: [])
    let fullB = KeySet(kind: "unique", keyColumns: ["email"], keys: ["V1:4"])
    let raggedRescue = TagMatcher.match(
        identity: identity([raggedA, fullB]), columns: [], rows: blankRows(1),
        tagsByIdentity: store([tag("trr", label: "teal", kind: "unique", value: "V1:4")]))
    expectLabel(raggedRescue, 0, "teal", "a short candidate still lets the next candidate match")

    // MARK: No identity block

    let none = TagMatcher.match(identity: nil, columns: [], rows: blankRows(3),
                                tagsByIdentity: store([tag("tn", label: "red", kind: "pk", value: "V1:1")]))
    expectEqual(none.count, 0, "no identity block matches nothing in the strong path")

    // MARK: - The weak path

    /// A fingerprint tag over the given columns and values.
    func fpTag(_ id: String, label: String, columns: [String], values: [String?],
               tableKey: String = "oid:1") -> RowTag {
        let value = RowFingerprint.encode(columns: columns, values: values) ?? ""
        return RowTag(id: id, connectionId: "c", labelId: label, note: nil,
                      primaryKind: "fingerprint", tableKey: tableKey, tableDisplay: "t",
                      identityColumns: columns, identityValues: values,
                      keys: [RowTagKey(identityKind: "fingerprint", identityValue: value)],
                      createdAt: "", updatedAt: "")
    }

    let weakId = identity([], tableKey: "oid:1", tableKeys: ["oid:1"])

    // A plain hit: the result holds exactly the stored columns.
    let hit = TagMatcher.match(
        identity: weakId, columns: ["id", "name"],
        rows: [["1", "Ada"], ["2", "Bob"]],
        tagsByIdentity: store([fpTag("f1", label: "red", columns: ["id", "name"], values: ["2", "Bob"])]))
    expectLabel(hit, 1, "red", "a fingerprint matches the row holding its values")
    expectLabel(hit, 0, nil, "the other row stays untagged")

    // Rule 2: EVERY stored column must be present. A narrower result matches
    // nothing — a partial overlap can match the wrong row.
    let narrower = TagMatcher.match(
        identity: weakId, columns: ["name"], rows: [["Ada"], ["Bob"]],
        tagsByIdentity: store([fpTag("f2", label: "red", columns: ["id", "name"], values: ["2", "Bob"])]))
    expectEqual(narrower.count, 0, "a result missing a stored column matches nothing")

    // A WIDER result still matches: the stored columns are all present, and the
    // extra ones are ignored.
    let wider = TagMatcher.match(
        identity: weakId, columns: ["id", "name", "status"],
        rows: [["2", "Bob", "active"]],
        tagsByIdentity: store([fpTag("f3", label: "blue", columns: ["id", "name"], values: ["2", "Bob"])]))
    expectLabel(wider, 0, "blue", "a wider result still matches on the stored columns")

    // Rule 3: an ambiguous fingerprint tags nothing. Two identical rows must not
    // both take the tag, and neither may take it arbitrarily.
    let ambiguous = TagMatcher.match(
        identity: weakId, columns: ["status"], rows: [["active"], ["active"]],
        tagsByIdentity: store([fpTag("f4", label: "red", columns: ["status"], values: ["active"])]))
    expectEqual(ambiguous.count, 0, "a fingerprint matching two rows tags neither")

    // Rule 1: the table sets must overlap.
    let otherTableFp = TagMatcher.match(
        identity: identity([], tableKey: "oid:1", tableKeys: ["oid:1"]),
        columns: ["id"], rows: [["1"]],
        tagsByIdentity: store([fpTag("f5", label: "red", columns: ["id"], values: ["1"], tableKey: "oid:777")]))
    expectEqual(otherTableFp.count, 0, "a fingerprint from another table does not match")

    // A join carries several table keys; a tag on any one of them may match.
    let joined = TagMatcher.match(
        identity: identity([], tableKey: "oid:1", tableKeys: ["oid:1", "oid:2"]),
        columns: ["id"], rows: [["1"]],
        tagsByIdentity: store([fpTag("f6", label: "green", columns: ["id"], values: ["1"], tableKey: "oid:2")]))
    expectLabel(joined, 0, "green", "a fingerprint on any table in the result may match")

    // A NULL in the row must encode as N and match a stored NULL.
    let nullRow = TagMatcher.match(
        identity: weakId, columns: ["id", "note"], rows: [["1", nil]],
        tagsByIdentity: store([fpTag("f7", label: "amber", columns: ["id", "note"], values: ["1", nil])]))
    expectLabel(nullRow, 0, "amber", "a NULL value matches a stored NULL")

    // A row shorter than the column list is malformed — PostgreSQL results are
    // rectangular, so this should not happen. The missing cell reads as nil (a
    // NULL), never as an empty string, which would silently claim a real value.
    // The strong path has its short-key-array equivalent; this is the weak one.
    //
    // The fixture's second stored value is a NULL, so the row's missing cell must
    // encode as `N` for the match to land. A fallback of `""` would encode `V0:`
    // and the match would fail — which is what makes this check discriminate.
    let shortRow = TagMatcher.match(
        identity: weakId, columns: ["id", "note"], rows: [["1"]],
        tagsByIdentity: store([fpTag("f10", label: "grey", columns: ["id", "note"], values: ["1", nil])]))
    expectLabel(shortRow, 0, "grey", "a short row reads its missing cell as NULL, not as empty text")

    // Rule 3, the other direction. Two fingerprint tags on the SAME table with
    // different column sets both match this row: one stored ["id"], one stored
    // ["id","name"]. Neither is applied. Before this rule the winner depended on
    // dictionary order and changed between runs of the same query.
    let twoGroupsOneRow = TagMatcher.match(
        identity: weakId, columns: ["id", "name"], rows: [["1", "Ada"]],
        tagsByIdentity: store([fpTag("g1", label: "narrow", columns: ["id"], values: ["1"]),
                               fpTag("g2", label: "wide", columns: ["id", "name"], values: ["1", "Ada"])]))
    expectEqual(twoGroupsOneRow.count, 0, "a row claimed by two fingerprint tags takes neither")

    // The same ambiguity across two TABLES. Both tags store ["id"] = "1" and both
    // encode to the same string, so grouping on columns alone made one silently
    // replace the other and rule 3 never saw the conflict.
    let twoTablesOneRow = TagMatcher.match(
        identity: identity([], tableKey: "oid:1", tableKeys: ["oid:1", "oid:2"]),
        columns: ["id"], rows: [["1"]],
        tagsByIdentity: store([fpTag("h1", label: "fromA", columns: ["id"], values: ["1"], tableKey: "oid:1"),
                               fpTag("h2", label: "fromB", columns: ["id"], values: ["1"], tableKey: "oid:2")]))
    expectEqual(twoTablesOneRow.count, 0, "a row claimed by tags on two tables takes neither")

    // Two tags in DIFFERENT groups each land on their own row. The cross-group
    // refusal is per ROW: a second group must not silence a row it never claimed.
    // Without this check, an implementation that refuses ANY multi-group result
    // passes the whole suite.
    let twoGroupsTwoRows = TagMatcher.match(
        identity: weakId, columns: ["id", "name"],
        rows: [["1", "Ada"], ["2", "Bob"]],
        tagsByIdentity: store([fpTag("k1", label: "narrow", columns: ["id"], values: ["1"]),
                               fpTag("k2", label: "wide", columns: ["id", "name"], values: ["2", "Bob"])]))
    expectEqual(twoGroupsTwoRows.count, 2, "two groups each claim their own row")
    expectLabel(twoGroupsTwoRows, 0, "narrow", "the narrow group claims row 0")
    expectLabel(twoGroupsTwoRows, 1, "wide", "the wide group claims row 1")

    // The two directions compose in order: an ambiguous fingerprint is removed from
    // contention by direction A, so it does not block a more specific tag from
    // claiming a row they both matched. The vaguer tag disqualified itself.
    let ambiguousThenSpecific = TagMatcher.match(
        identity: weakId, columns: ["status", "id"],
        rows: [["active", "1"], ["active", "2"]],
        tagsByIdentity: store([fpTag("m1", label: "vague", columns: ["status"], values: ["active"]),
                               fpTag("m2", label: "specific", columns: ["status", "id"], values: ["active", "1"])]))
    expectLabel(ambiguousThenSpecific, 0, "specific", "an ambiguous tag does not block a specific one")
    expectLabel(ambiguousThenSpecific, 1, nil, "the row only the ambiguous tag matched stays untagged")

    // Two different fingerprint tags in one result each find their own row.
    let twoTags = TagMatcher.match(
        identity: weakId, columns: ["id"], rows: [["1"], ["2"]],
        tagsByIdentity: store([fpTag("f8", label: "red", columns: ["id"], values: ["1"]),
                               fpTag("f9", label: "blue", columns: ["id"], values: ["2"])]))
    expectEqual(twoTags.count, 2, "two fingerprint tags find two rows")
    expectLabel(twoTags, 0, "red", "the first fingerprint finds row 0")
    expectLabel(twoTags, 1, "blue", "the second fingerprint finds row 1")

    // A strong tag must not be reachable from the weak path, and the reverse.
    let strongInWeak = TagMatcher.match(
        identity: weakId, columns: ["id"], rows: [["1"]],
        tagsByIdentity: store([tag("ts2", label: "red", kind: "pk", value: "V1:1")]))
    expectEqual(strongInWeak.count, 0, "the weak path does not reach a pk tag")

    if failures == 0 {
        print("\nAll TagMatcher tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
