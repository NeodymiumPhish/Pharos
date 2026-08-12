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

    // MARK: Check 9 — the ordering guarantee, on a failure that is actually reachable

    // An unknown connection id cannot make `loadRowTags` fail — it just returns an
    // empty list — so it cannot tell `load`'s correct ordering apart from a mutant
    // that assigns `labels` before the second FFI call: both calls share one SQLite
    // connection behind one mutex, so a whole-database failure (a locked file, a
    // poisoned mutex) would hit `loadTagLabels` FIRST and neither implementation
    // would reach the second assignment either way.
    //
    // What discriminates is a failure specific to the row-tag tables while
    // `tag_labels` stays readable. Dropping `row_tags` and `row_tag_keys` from
    // OUTSIDE the FFI, with the `sqlite3` CLI against the same file, does exactly
    // that: `loadTagLabels` still succeeds and `loadRowTags` throws. Corrupting the
    // file instead would break `loadTagLabels` too, and this check would prove
    // nothing — see the paragraph above.
    attempt("check 9 setup") {
        let orderConn = "conn-tagstore-order"

        let l1 = try PharosCore.createTagLabel(CreateTagLabel(name: "OrderCheckL1", colorIndex: 3))
        try TagStore.shared.load(connectionId: orderConn)
        expectTrue(TagStore.shared.labels.contains(where: { $0.id == l1.id }),
                   "load before the drop picks up L1")

        // Created AFTER the last successful load and never loaded. It must not
        // appear in `labels` until a load actually succeeds again.
        let l2 = try PharosCore.createTagLabel(CreateTagLabel(name: "OrderCheckL2", colorIndex: 4))

        let dbPath = (dir as NSString).appendingPathComponent("pharos.db")
        let sqlite3Path = "/usr/bin/sqlite3"
        guard FileManager.default.isExecutableFile(atPath: sqlite3Path) else {
            fail("check 9 setup", "\(sqlite3Path) is not present or not executable; cannot drop the row-tag tables")
            return
        }
        let drop = Process()
        drop.executableURL = URL(fileURLWithPath: sqlite3Path)
        drop.arguments = [dbPath, "DROP TABLE row_tag_keys; DROP TABLE row_tags;"]
        let stderrPipe = Pipe()
        drop.standardError = stderrPipe
        try drop.run()
        drop.waitUntilExit()
        guard drop.terminationStatus == 0 else {
            let stderrText = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            fail("check 9 setup", "sqlite3 DROP TABLE exited \(drop.terminationStatus): \(stderrText)")
            return
        }

        // Clear the cached entry first, or the idempotency guard added in check 1a
        // would skip the reload entirely and this would test nothing.
        TagStore.shared.clear(connectionId: orderConn)

        var threw = false
        do {
            try TagStore.shared.load(connectionId: orderConn)
        } catch {
            threw = true
        }
        expectTrue(threw, "load throws once the row-tag tables are gone")

        expectTrue(TagStore.shared.labels.contains(where: { $0.id == l1.id }),
                   "labels still holds L1 after the failed reload")
        expectTrue(!TagStore.shared.labels.contains(where: { $0.id == l2.id }),
                   "labels does NOT hold L2 — the failed second call must not let the first assignment through")
    }

    pharos_shutdown()

    if failures == 0 {
        print("\nAll TagStore checks passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
