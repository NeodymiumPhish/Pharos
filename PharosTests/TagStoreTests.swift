// Live runner for TagStore. Links the real Rust staticlib and
// writes a real SQLite file; it needs no PostgreSQL, because tags are local.
//
// The binary runs TWICE against one mktemp -d — the second process is what
// proves the write survived a restart, which is the "quit the app and open it
// again" of the manual check.
//
// The directory is never the real Application Support path, so this cannot
// touch the user's own tags, connections or settings.
import Foundation
import CPharosCore

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

private func newTuple(_ value: String) -> NewTagRule {
    let normalized = TagValueNormalizer.normalize(value, family: "text")
    let taggedValue = TagCondition(column: "md5", family: "text",
                                  value: normalized, display: value)
    return NewTagRule(
        conditions: [taggedValue],
        tupleKey: RuleKey.encode([RuleConditionKey(kind: .exact, family: "text",
                                                   value: normalized, operand2: nil)])!,
        originConnection: "c1", originTable: "public.certs")
}

@MainActor
func writePhase() {
    let store = TagStore.shared
    do {
        let created = try store.createTag(CreateTag(
            name: "Suspect infra", colorIndex: 2, note: "may sprint",
            rules: [newTuple("D41D8C"), newTuple("AABBCC")]))
        expectEqual(created.rules.count, 2, "create stores both tuples")
        expectEqual(store.tags.count, 1, "the cache holds the new tag")
        expectTrue(!store.tagIndex.isEmpty, "the probe index is rebuilt on write")

        // Add-to-existing, with one repeat the unique index must absorb.
        let added = try store.addTuples(AddTagRules(
            tagId: created.id, rules: [newTuple("AABBCC"), newTuple("DDEEFF")]))
        expectEqual(added, 1, "a repeated tuple is a no-op")
        expectEqual(store.tag(id: created.id)?.rules.count, 3, "the tag grew by one")

        // The store is GLOBAL: no connection argument anywhere above.
        let columns = [ColumnDef(name: "hash", dataType: "text")]
        let rows: [[String?]] = [["d41d8c"], ["nothing"], ["ddeeff"]]
        let matches = TagRuleMatcher.match(columns: columns, rows: rows, index: store.tagIndex)
        expectEqual(matches.count, 2, "the cached index matches a foreign result")
        expectEqual(matches[0]?[0].state, .solid, "a one-value tuple is solid")
    } catch {
        failures += 1
        print("FAIL write phase threw \(error)")
    }
}

@MainActor
func readPhase() {
    let store = TagStore.shared
    do {
        try store.loadTagsIfNeeded()
        expectEqual(store.tags.count, 1, "the tag survived the restart")
        guard let tag = store.tags.first else { return }
        expectEqual(tag.name, "Suspect infra", "the name survived")
        expectEqual(tag.note, "may sprint", "the note survived")
        expectEqual(tag.rules.count, 3, "every tuple survived")

        // Remove two tuples: the tag itself SURVIVES an empty tuple list — it is
        // still a named case the analyst may grow again.
        let ids = tag.rules.prefix(3).map { $0.id }
        try store.removeTuples(ids: Array(ids))
        expectEqual(store.tags.count, 1, "a tag with no tuples still exists")
        expectEqual(store.tags.first?.rules.isEmpty, true, "its tuples are gone")
        expectTrue(store.tagIndex.isEmpty, "an empty tag indexes nothing")

        try store.deleteTag(id: tag.id)
        expectEqual(store.tags.isEmpty, true, "delete removes the tag")
    } catch {
        failures += 1
        print("FAIL read phase threw \(error)")
    }
}

func runTests() {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        print("usage: tag-store-tests <write|read> <dir>")
        exit(2)
    }
    args[2].withCString { pharos_init($0) }
    MainActor.assumeIsolated {
        if args[1] == "write" { writePhase() } else { readPhase() }
    }
    print(failures == 0 ? "\nAll unified TagStore checks passed" : "\n\(failures) FAILED")
    if failures > 0 { exit(1) }
}
