// Standalone runner for TagRuleMatcher — the probe index, the solid/dashed
// rule, and the ordering that decides which tag owns a row's bar.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// MARK: Fixtures

private func value(_ family: String, _ text: String) -> TagCondition {
    TagCondition(family: family,
                value: TagValueNormalizer.normalize(text, family: family), display: text)
}

private func tuple(_ id: String, _ values: [TagCondition]) -> TagRule {
    TagRule(id: id, conditions: values, tupleKey: RuleKey.encode(
                values.map { RuleConditionKey(kind: $0.kind, family: $0.family,
                                              value: $0.value, operand2: $0.operand2) }) ?? "",
             originConnection: "c1", originTable: "public.certs",
             createdAt: "2026-08-13T00:00:00Z")
}

private func tag(_ id: String, _ tuples: [TagRule]) -> Tag {
    Tag(id: id, name: id, colorIndex: 0, note: nil,
        createdAt: "2026-08-13T00:00:00Z", updatedAt: "2026-08-13T00:00:00Z", rules: tuples)
}

private let columns = [
    ColumnDef(name: "md5", dataType: "text"),
    ColumnDef(name: "subject", dataType: "text"),
    ColumnDef(name: "ip", dataType: "inet"),
    ColumnDef(name: "port", dataType: "int4"),
]

func runTests() {
    // A single-column tag: every tuple is one value wide, so any hit is
    // complete — the md5 case draws solid.
    let md5Tag = tag("md5-tag", [
        tuple("t1", [value("text", "D41D8C")]),
        tuple("t2", [value("text", "AABBCC")]),
    ])
    // A two-column tag: one tuple per tagged row.
    let pairTag = tag("pair-tag", [
        tuple("p1", [value("address", "10.2.3.4"), value("text", "CN=evil")]),
        tuple("p2", [value("address", "10.9.9.9"), value("text", "CN=other")]),
    ])

    let index = TagRuleMatcher.buildIndex([md5Tag, pairTag])

    // 1. Solid on a single-column tag, matched under a DIFFERENT column name in
    //    a different case — the whole point of value identity.
    let rows: [[String?]] = [
        ["d41d8c", "CN=unrelated", "192.0.2.1", "443"],   // 0: md5 solid
        ["nope", "CN=evil", "10.2.3.4", "443"],           // 1: pair solid
        ["nope", "CN=other", "10.2.3.4", "443"],          // 2: pair dashed, cross-tuple
        ["nope", "CN=unrelated", "192.0.2.9", "443"],     // 3: no match
        ["aabbcc", "CN=evil", "10.2.3.4", "8443"],        // 4: both tags, both solid
    ]
    let matches = TagRuleMatcher.match(columns: columns, rows: rows, index: index)

    expectEqual(matches[0]?.count, 1, "row 0 matches one tag")
    expectEqual(matches[0]?[0].tagId, "md5-tag", "row 0 is the md5 tag")
    expectEqual(matches[0]?[0].state, .solid, "a one-value tuple is solid on any hit")
    expectEqual(matches[0]?[0].matchedColumns, [0], "row 0 matched the md5 column")

    expectEqual(matches[1]?[0].state, .solid, "both values of one tuple are solid")
    expectEqual(matches[1]?[0].matchedColumns, [1, 2], "row 1 matched subject and ip")
    expectEqual(matches[1]?[0].solidRuleIds, ["p1"], "row 1 names the complete tuple")

    // 2. Cross-row combinations are dashed by definition: row 2 holds p1's
    //    address and p2's subject, and no single tuple is complete.
    expectEqual(matches[2]?[0].state, .dashed, "values from different tuples are dashed")
    expectEqual(matches[2]?[0].matchedRuleIds, ["p1", "p2"], "both origin tuples are named")
    expectEqual(matches[2]?[0].solidRuleIds, [], "a dashed match names no complete tuple")

    // 3. No match at all leaves the row out of the map entirely.
    expectEqual(matches[3] == nil, true, "an unmatched row is absent")

    // 4. Multi-tag rows carry every match, strongest first.
    expectEqual(matches[4]?.count, 2, "row 4 matches both tags")
    expectEqual(matches[4]?[0].tagId, "pair-tag", "more matched values ranks first")
    expectEqual(matches[4]?[1].tagId, "md5-tag", "the one-value match ranks second")

    // 5. Solid beats dashed whatever the value counts say.
    let ordered = TagRuleMatcher.ordered([
        TagRowMatch(tagId: "b", state: .dashed, matchedColumns: [0, 1, 2],
                    matchedRuleIds: [], solidRuleIds: []),
        TagRowMatch(tagId: "a", state: .solid, matchedColumns: [0],
                    matchedRuleIds: [], solidRuleIds: ["x"]),
    ])
    expectEqual(ordered[0].tagId, "a", "solid outranks a wider dashed match")

    // 6. A NULL cell never matches, not even a tuple that lost its own value.
    let nullRows: [[String?]] = [[nil, nil, nil, nil]]
    expectEqual(TagRuleMatcher.match(columns: columns, rows: nullRows, index: index).isEmpty,
                true, "an all-NULL row matches nothing")

    // 7. A tuple with no values is inert, not a match on everything. Zero slots
    //    would otherwise read as "every slot satisfied" and paint the grid.
    let emptyIndex = TagRuleMatcher.buildIndex([tag("empty", [tuple("e1", [])])])
    expectEqual(TagRuleMatcher.match(columns: columns, rows: rows, index: emptyIndex).isEmpty,
                true, "a valueless tuple matches nothing")

    // 8. The family gates the compare: "443" in an int4 column never matches
    //    "443" tagged from a text column.
    let textPort = TagRuleMatcher.buildIndex(
        [tag("t", [tuple("x", [value("text", "443")])])])
    expectEqual(TagRuleMatcher.match(columns: columns, rows: rows, index: textPort).isEmpty,
                true, "a text 443 does not match a numeric 443")

    // 9. An empty index short-circuits, and so does a result with no column of
    //    any tagged family.
    expectEqual(TagRuleMatcher.match(columns: columns, rows: rows,
                                      index: TagRuleMatcher.buildIndex([])).isEmpty,
                true, "no tags, no work")
    let jsonOnly = [ColumnDef(name: "doc", dataType: "jsonb")]
    expectEqual(TagRuleMatcher.match(columns: jsonOnly, rows: [["x"]], index: index).isEmpty,
                true, "no column of a tagged family, no work")

    // 10. One value satisfies every slot that holds it: a tuple capturing the
    //     same value twice is solid on a single hit.
    let twiceIndex = TagRuleMatcher.buildIndex([tag("twice", [
        tuple("d1", [value("text", "dup"), value("text", "dup")])])])
    let twiceRows: [[String?]] = [["dup", "unrelated", "192.0.2.1", "1"]]
    expectEqual(TagRuleMatcher.match(columns: columns, rows: twiceRows,
                                      index: twiceIndex)[0]?[0].state, .solid,
                "presence, not multiplicity, satisfies a slot")

    // 11. A short row (fewer cells than columns) degrades, never traps.
    expectEqual(TagRuleMatcher.match(columns: columns, rows: [["d41d8c"]],
                                      index: index)[0]?[0].tagId, "md5-tag",
                "a short row still matches what it holds")

    // 12. The tie-break, pinned. Both tags are solid and both matched exactly
    //     one value, so state and matched-count decide nothing and only the id
    //     is left. Without a total order here the two could swap between runs
    //     of the same query — and the bar colour of a two-tag row would change
    //     at random. A dictionary's iteration order is not stable, so this is a
    //     real risk, not a theoretical one.
    let tieIndex = TagRuleMatcher.buildIndex([
        tag("a-tag", [tuple("a1", [value("text", "zzz")])]),
        tag("b-tag", [tuple("b1", [value("text", "yyy")])]),
    ])
    let tieRows: [[String?]] = [["zzz", "yyy", "192.0.2.1", "1"]]
    let tieMatches = TagRuleMatcher.match(columns: columns, rows: tieRows, index: tieIndex)
    expectEqual(tieMatches[0]?[0].tagId, "a-tag",
                "the tag id is the only remaining tie-break")

    // MARK: pattern conditions

    func cond(_ kind: TagConditionKind, _ family: String, _ raw: String,
              _ operand2: String? = nil) -> TagCondition {
        TagCondition(family: family, kind: kind,
                     value: TagValueNormalizer.normalize(raw, family: family),
                     operand2: operand2.map { TagValueNormalizer.normalize($0, family: family) },
                     display: raw)
    }

    let addressColumn = ColumnDef(name: "ip_addr", dataType: "inet")
    let hostColumn = ColumnDef(name: "host", dataType: "text")
    let portColumn = ColumnDef(name: "port", dataType: "int4")
    let schema = [addressColumn, hostColumn, portColumn]

    let sample: [[String?]] = [
        ["107.8.8.1", "neodymiumphi.sh", "443"],           // 0
        ["107.8.8.1", "network.neodymiumphi.sh", "8443"],  // 1
        ["203.0.113.9", "example.org", "80"],              // 2
        ["107.8.9.1", "other.neodymiumphi.sh", "22"],      // 3
    ]

    // The case this whole feature exists for: an exact address AND a glob host
    // in ONE rule. Both rows go solid, where an exact-only tag left row 1 dashed.
    let mixed = tag("mixed", [tuple("r1", [
        cond(.exact, "address", "107.8.8.1"),
        cond(.glob, "text", "*neodymiumphi.sh"),
    ])])
    let mixedResult = TagRuleMatcher.match(
        columns: schema, rows: sample, index: TagRuleMatcher.buildIndex([mixed]))
    expectEqual(mixedResult[0]?.first?.state, .solid, "row 0 solid on exact + glob")
    expectEqual(mixedResult[1]?.first?.state, .solid, "row 1 solid on exact + glob")
    expectEqual(mixedResult[2] == nil, true, "row 2 does not match at all")
    // Row 3's host matches the glob but its address does not, so the rule is
    // incomplete: dashed, exactly as a half-matched exact rule would be.
    expectEqual(mixedResult[3]?.first?.state, .dashed, "row 3 dashed on the glob alone")

    // A rule made ONLY of patterns can go solid. This is the case that breaks
    // if `Index.isEmpty` still tests only `slots`.
    let cidrTag = tag("cidr", [tuple("r2", [cond(.cidr, "address", "107.8.8.0/24")])])
    let cidrIndex = TagRuleMatcher.buildIndex([cidrTag])
    expectEqual(cidrIndex.isEmpty, false, "an index holding only patterns is not empty")
    let cidrResult = TagRuleMatcher.match(columns: schema, rows: sample, index: cidrIndex)
    expectEqual(cidrResult[0]?.first?.state, .solid, "cidr matches 107.8.8.1")
    expectEqual(cidrResult[1]?.first?.state, .solid, "cidr matches the second 107.8.8.1")
    expectEqual(cidrResult[3] == nil, true, "cidr does not reach 107.8.9.1")

    // A CIDR condition also reaches an address stored in a TEXT column.
    let textSchema = [ColumnDef(name: "src", dataType: "text")]
    let textRows: [[String?]] = [["107.8.8.1"], ["not an address"], ["203.0.113.9"]]
    let textResult = TagRuleMatcher.match(
        columns: textSchema, rows: textRows, index: cidrIndex)
    expectEqual(textResult[0]?.first?.state, .solid, "cidr reaches an address in a text column")
    expectEqual(textResult[1] == nil, true, "cidr ignores text that is not an address")
    expectEqual(textResult[2] == nil, true, "cidr ignores an address outside it")

    // A comparator, and the matched column is reported so the grid can tint it.
    let portTag = tag("ports", [tuple("r3", [cond(.greaterThan, "numeric", "1000")])])
    let portResult = TagRuleMatcher.match(
        columns: schema, rows: sample, index: TagRuleMatcher.buildIndex([portTag]))
    expectEqual(portResult[1]?.first?.state, .solid, "8443 is above 1000")
    expectEqual(portResult[0] == nil, true, "443 is not above 1000")
    expectEqual(portResult[1]?.first?.matchedColumns, [2], "the port column is the matched one")

    // A numeric comparator must NOT sweep the text columns.
    let sweepRows: [[String?]] = [["1.1.1.1", "9999", "5"]]
    let sweepResult = TagRuleMatcher.match(
        columns: schema, rows: sweepRows, index: TagRuleMatcher.buildIndex([portTag]))
    expectEqual(sweepResult[0] == nil, true, "a numeric comparator ignores a numeric-looking text cell")

    // A rule with a condition this build cannot evaluate is skipped WHOLE. A
    // rule missing one condition is EASIER to satisfy than the analyst wrote,
    // and a too-easy rule is a false match.
    let future = tag("future", [tuple("r4", [
        cond(.exact, "address", "107.8.8.1"),
        TagCondition(family: "text", kind: .unsupported("startsWith"),
                     value: "neo", operand2: nil, display: "neo"),
    ])])
    let futureResult = TagRuleMatcher.match(
        columns: schema, rows: sample, index: TagRuleMatcher.buildIndex([future]))
    expectEqual(futureResult.isEmpty, true,
                "a rule with an unsupported condition matches nothing at all")

    // The same for an operand that cannot be parsed.
    let broken = tag("broken", [tuple("r5", [cond(.cidr, "address", "10.2.3.999")])])
    expectEqual(TagRuleMatcher.buildIndex([broken]).isEmpty, true,
                "a malformed CIDR builds no index")

    // THE regression guard: with no patterns, the result must be what today's
    // code produces. This is the promise that a user who authors no condition
    // cannot be regressed.
    let exactOnly = tag("exact", [tuple("r6", [
        cond(.exact, "address", "107.8.8.1"),
        cond(.exact, "text", "neodymiumphi.sh"),
    ])])
    let exactResult = TagRuleMatcher.match(
        columns: schema, rows: sample, index: TagRuleMatcher.buildIndex([exactOnly]))
    expectEqual(exactResult.count, 2, "exact-only tag touches exactly two rows")
    expectEqual(exactResult[0]?.first?.state, .solid, "exact-only row 0 solid")
    expectEqual(exactResult[1]?.first?.state, .dashed, "exact-only row 1 dashed as before")
    expectEqual(exactResult[0]?.first?.solidRuleIds, ["r6"], "the solid rule is reported")

    print(failures == 0 ? "\nAll matcher checks passed" : "\n\(failures) FAILED")
    if failures > 0 { exit(1) }
}
