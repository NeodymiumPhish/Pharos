// Standalone runner for the unified tag models. Pins the WIRE TEXT, because
// Swift is the only producer of the three write payloads: nothing on the Rust
// side can catch a casing mistake in them until run time.
import Foundation

var failures = 0

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    let encoder = JSONEncoder()

    // 1. CreateTag encodes camelCase keys, with no key strategy applied.
    let create = CreateTag(
        name: "Suspect infra", colorIndex: 2, note: "may sprint",
        rules: [NewTagRule(
            conditions: [TagCondition(column: "md5", family: "text",
                                 value: "d41d8c", display: "D41D8C")],
            tupleKey: "K4:textV6:d41d8c",
            originConnection: "c1", originTable: "public.certs")])
    let createText = String(data: try! encoder.encode(create), encoding: .utf8)!
    expectTrue(createText.contains("\"colorIndex\":2"), "CreateTag emits colorIndex")
    expectTrue(createText.contains("\"tupleKey\""), "CreateTag emits tupleKey")
    expectTrue(createText.contains("\"originConnection\""), "CreateTag emits originConnection")
    expectTrue(!createText.contains("color_index"), "CreateTag emits no snake_case key")

    // 2. AddTagRules and UpdateTag likewise.
    let add = AddTagRules(tagId: "t1", rules: [])
    expectTrue(String(data: try! encoder.encode(add), encoding: .utf8)!.contains("\"tagId\""),
               "AddTagRules emits tagId")
    let update = UpdateTag(id: "t1", name: "Renamed", colorIndex: 4, note: nil)
    let updateText = String(data: try! encoder.encode(update), encoding: .utf8)!
    expectTrue(updateText.contains("\"colorIndex\":4"), "UpdateTag emits colorIndex")

    // 3. A Tag decodes from the exact document Rust emits.
    let wire = """
    {"id":"t1","name":"Suspect infra","colorIndex":2,"note":null,
     "createdAt":"2026-08-13T00:00:00Z","updatedAt":"2026-08-13T00:00:00Z",
     "rules":[{"id":"u1","conditions":[{"column":"md5","family":"text",
     "value":"d41d8c","display":"D41D8C"}],"tupleKey":"K4:textV6:d41d8c",
     "originConnection":"c1","originTable":"public.certs",
     "createdAt":"2026-08-13T00:00:00Z"}]}
    """
    let tag = try! JSONDecoder().decode(Tag.self, from: Data(wire.utf8))
    expectEqual(tag.colorIndex, 2, "Tag decodes colorIndex")
    expectEqual(tag.note, nil, "Tag decodes a null note as nil")
    expectEqual(tag.rules.count, 1, "Tag decodes its tuples")
    expectEqual(tag.rules[0].conditions[0].display, "D41D8C", "TagCondition decodes display")
    expectEqual(tag.rules[0].originTable, "public.certs", "TagRule decodes originTable")

    print(failures == 0 ? "\nAll tag model checks passed" : "\n\(failures) FAILED")
    if failures > 0 { exit(1) }
}
