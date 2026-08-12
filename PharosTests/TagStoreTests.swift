// Standalone integration runner for TagStore — Task 6 of the tag row phase 2
// plan.
//
// Like RowTagFFILiveTests.swift, this links the real Rust staticlib and writes a
// real SQLite file. It needs no PostgreSQL: row tags are local. Unlike that
// suite, ONE process is enough — this is not testing persistence across a
// restart, it is testing that TagStore builds the right in-memory index from
// what the FFI hands back, which is a within-process question.
//
// The directory is a mktemp -d, never the real Application Support path, so this
// cannot touch the user's own tags, connections or settings. Driven by
// scripts/test-tag-store.sh.
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

func fail(_ name: String, _ detail: String) {
    failures += 1
    print("FAIL \(name)\n  \(detail)")
}

/// Run `body` and report the failure instead of trapping, so one broken step does
/// not hide the rest of the evidence.
func attempt(_ name: String, _ body: () throws -> Void) {
    do { try body() } catch { fail(name, "threw \(error)") }
}

// Two distinct connection ids, so check 6 (per-connection scoping) has something
// real to distinguish.
let CONN = "conn-tagstore-a"
let OTHER_CONN = "conn-tagstore-b"

// `TagStore` is `@MainActor`, so the body must run on the main actor.
// `PharosTests/main.swift` calls `runTests()` from the top level of a
// `main.swift`, which this compiler build does not treat as implicitly
// main-actor-isolated context — so rather than mark `runTests()` itself
// `@MainActor` (which `main.swift`, shared by every other suite, cannot then
// call), the whole body runs inside `MainActor.assumeIsolated`. That is safe:
// this binary is single-threaded and `runTests()` runs on the process's one and
// only (main) thread.
func runTests() {
    MainActor.assumeIsolated {
        runMainActorTests()
    }
}

@MainActor
func runMainActorTests() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        print("usage: \(args.first ?? "binary") <app-data-dir>")
        print("Run it through scripts/test-tag-store.sh, which supplies a temp directory.")
        exit(2)
    }
    let dir = args[1]

    guard dir.withCString({ pharos_init($0) }) else {
        print("FAIL pharos_init(\(dir)) returned false")
        exit(1)
    }
    print("--- TagStore checks, store at \(dir) ---")

    // MARK: Check 1 — a fresh store is empty

    expectEqual(TagStore.shared.index(for: CONN).count, 0,
                "a fresh store's index is empty for any connection id")

    // MARK: Notification observer — set up before the first load, so it also
    // catches check 8's second post from `clear`.

    var notificationCount = 0
    let token = NotificationCenter.default.addObserver(
        forName: TagStore.didChange, object: nil, queue: nil
    ) { _ in notificationCount += 1 }

    // MARK: Write a label and a two-key tag through the FFI

    var label: TagLabel?
    attempt("create a label") {
        label = try PharosCore.createTagLabel(CreateTagLabel(name: "StoreCheck", colorIndex: 2))
    }
    guard let label else {
        fail("write phase", "no label to tag with; the rest of the checks cannot run")
        NotificationCenter.default.removeObserver(token)
        pharos_shutdown()
        exit(1)
    }

    var tagId: String?
    attempt("write a two-key tag") {
        let upsert = UpsertRowTag(
            connectionId: CONN,
            labelId: label.id,
            note: nil,
            primaryKind: "pk",
            tableKey: "oid:1",
            tableDisplay: "public.widgets",
            identityColumns: ["id"],
            identityValues: ["1"],
            keys: [RowTagKey(identityKind: "pk", identityValue: "V1:1"),
                   RowTagKey(identityKind: "unique", identityValue: "V6:a@b.co")]
        )
        let tag = try PharosCore.upsertRowTag(upsert)
        tagId = tag.id
    }
    guard let tagId else {
        fail("write phase", "no tag id; the rest of the checks cannot run")
        NotificationCenter.default.removeObserver(token)
        pharos_shutdown()
        exit(1)
    }

    // MARK: Load into the store

    attempt("load the connection's tags") {
        try TagStore.shared.load(connectionId: CONN)
    }

    // MARK: Check 2 — one entry per stored key, not per tag

    let index = TagStore.shared.index(for: CONN)
    expectEqual(index.count, 2,
                "a single two-key tag produces exactly 2 index entries, one per key")

    // MARK: Check 3 — both entries resolve to the same tag

    let ids = Set(index.values.map { $0.id })
    expectEqual(ids.count, 1, "both index entries resolve to the same tag id")
    expectEqual(ids.first, tagId, "the resolved tag id matches the one the FFI returned")

    // MARK: Check 4 — each entry is reachable under its own kind's composite key

    let pkKey = TagMatcher.compositeKey(tableKey: "oid:1", kind: "pk", value: "V1:1")
    let uniqueKey = TagMatcher.compositeKey(tableKey: "oid:1", kind: "unique", value: "V6:a@b.co")
    expectEqual(index[pkKey]?.id, tagId, "the pk key resolves to the tag")
    expectEqual(index[uniqueKey]?.id, tagId, "the unique key resolves to the same tag")

    // MARK: Check 5 — labels holds the created label after load

    expectTrue(TagStore.shared.labels.contains(where: { $0.id == label.id && $0.name == "StoreCheck" }),
               "labels holds the created label after load")

    // MARK: Check 6 — index(for:) is scoped per connection

    expectEqual(TagStore.shared.index(for: OTHER_CONN).count, 0,
                "a different connection id gives an empty index even though the store holds tags")

    // MARK: Check 7 — clear empties that connection's index

    TagStore.shared.clear(connectionId: CONN)
    expectEqual(TagStore.shared.index(for: CONN).count, 0,
                "clear(connectionId:) empties that connection's index")

    // MARK: Check 8 — didChange fired once for load, once for clear

    expectEqual(notificationCount, 2, "didChange fires once on load and once on clear")
    NotificationCenter.default.removeObserver(token)

    pharos_shutdown()

    if failures == 0 {
        print("\nAll TagStore checks passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
