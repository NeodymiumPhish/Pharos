// Standalone runner: matching a Load More page on its own and merging it
// (`TagRuleMatcher.appendingPage`) gives the same map as matching every row.
// Compiled by scripts/test-tag-incremental-match.sh.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func cond(_ kind: TagConditionKind, _ family: String, _ raw: String,
                  _ operand2: String? = nil) -> TagCondition {
    TagCondition(family: family, kind: kind,
                 value: TagValueNormalizer.normalize(raw, family: family),
                 operand2: operand2.map { TagValueNormalizer.normalize($0, family: family) },
                 display: raw)
}

private func rule(_ id: String, _ conditions: [TagCondition]) -> TagRule {
    TagRule(id: id, conditions: conditions, tupleKey: RuleKey.encode(
                conditions.map { RuleConditionKey(kind: $0.kind, family: $0.family,
                                                  value: $0.value, operand2: $0.operand2) }) ?? "",
            originConnection: "c1", originTable: "public.t", createdAt: "2026-11-06T00:00:00Z")
}

private func tag(_ id: String, _ rules: [TagRule]) -> Tag {
    Tag(id: id, name: id, colorIndex: 0, note: nil,
        createdAt: "2026-11-06T00:00:00Z", updatedAt: "2026-11-06T00:00:00Z", rules: rules)
}

func runTests() {
    let columns = [
        ColumnDef(name: "ip", dataType: "inet"),
        ColumnDef(name: "host", dataType: "text"),
        ColumnDef(name: "port", dataType: "int4"),
        ColumnDef(name: "seen", dataType: "timestamptz"),
        ColumnDef(name: "doc", dataType: "jsonb"),
    ]
    // Values repeat across rows on purpose: the pattern overlay is a memo keyed
    // by distinct value, so a value seen in BOTH halves is the case to prove.
    let hosts = ["neodymiumphi.sh", "network.neodymiumphi.sh", "example.org", "other.neodymiumphi.sh", "evil.test"]
    let ips = ["107.8.8.1", "107.8.9.1", "203.0.113.9", "10.2.3.4", "not an address"]
    var rows: [[String?]] = []
    for i in 0..<240 {
        let ip: String? = i % 11 == 0 ? nil : ips[i % ips.count]
        let host = hosts[(i * 7) % hosts.count]
        let port = String([22, 80, 443, 8443, 1000, 1001][i % 6])
        let seen = "2026-0\(1 + i % 9)-1\(i % 10) 12:00:00+00"
        let doc = "{\"host\": \"\(hosts[(i * 3) % hosts.count])\", \"n\": \(i % 13)}"
        // Some rows are short: a page can hold ragged rows too.
        rows.append(i % 37 == 5 ? [ip, host] : [ip, host, port, seen, doc])
    }

    let tags: [(String, Tag)] = [
        ("exact", tag("exact", [rule("e1", [cond(.exact, "text", "example.org")]),
                                rule("e2", [cond(.exact, "address", "10.2.3.4"), cond(.exact, "text", "evil.test")])])),
        ("glob", tag("glob", [rule("g1", [cond(.glob, "text", "*neodymiumphi.sh")])])),
        ("cidr", tag("cidr", [rule("c1", [cond(.cidr, "address", "107.8.8.0/24")])])),
        ("greaterThan", tag("gt", [rule("n1", [cond(.greaterThan, "numeric", "1000")])])),
        ("greaterOrEqual", tag("ge", [rule("n2", [cond(.greaterOrEqual, "numeric", "1000")])])),
        ("lessThan", tag("lt", [rule("n3", [cond(.lessThan, "numeric", "100")])])),
        ("lessOrEqual", tag("le", [rule("n4", [cond(.lessOrEqual, "numeric", "80")])])),
        ("between", tag("bt", [rule("n5", [cond(.between, "numeric", "80", "1000")])])),
        ("temporal between", tag("tb", [rule("d1", [cond(.between, "temporal", "2026-03-01 00:00:00+00", "2026-05-31 00:00:00+00")])])),
        ("mixed exact + glob", tag("mx", [rule("m1", [cond(.exact, "address", "107.8.8.1"), cond(.glob, "text", "*neodymiumphi.sh")])])),
    ]

    let everyTag = tags.map(\.1)
    let cases = tags + [("all tags together", tag("unused", []))]
    for (label, single) in cases {
        let index = label == "all tags together"
            ? TagRuleMatcher.buildIndex(everyTag)
            : TagRuleMatcher.buildIndex([single])
        let whole = TagRuleMatcher.match(columns: columns, rows: rows, index: index)
        expectEqual(whole.isEmpty, false, "\(label): the fixture matches some rows")
        for split in [1, 100, 119, 200, 239] {
            let first = TagRuleMatcher.match(columns: columns, rows: Array(rows[..<split]), index: index)
            let page = TagRuleMatcher.match(columns: columns, rows: Array(rows[split...]), index: index)
            expectEqual(TagRuleMatcher.appendingPage(page, to: first, offset: split), whole,
                        "\(label): page at \(split) merged = whole match")
        }
    }

    // Three pages in a row, as three Load More presses give.
    let index = TagRuleMatcher.buildIndex(everyTag)
    var grown = TagRuleMatcher.match(columns: columns, rows: Array(rows[..<60]), index: index)
    for (start, end) in [(60, 130), (130, 200), (200, 240)] {
        let page = TagRuleMatcher.match(columns: columns, rows: Array(rows[start..<end]), index: index)
        grown = TagRuleMatcher.appendingPage(page, to: grown, offset: start)
    }
    expectEqual(grown, TagRuleMatcher.match(columns: columns, rows: rows, index: index),
                "three pages merged = whole match")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
