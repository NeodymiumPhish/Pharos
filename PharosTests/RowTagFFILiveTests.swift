// Standalone integration runner for the row tag FFI — Task 11 Step 5 of
// docs/superpowers/plans/2026-08-11-tag-row-phase-1.md.
//
// Unlike every other suite under PharosTests/, this one links the real Rust
// staticlib and writes a real SQLite file. It needs no PostgreSQL: the tag store
// is local, and `row_tags.connection_id` carries no foreign key, so a connection
// row is never necessary.
//
// It runs as TWO processes against ONE directory, which is what makes the
// persistence claim honest — `write` then `read`, driven by
// scripts/test-row-tag-ffi.sh. A single process could only prove the in-memory
// handle, since `pharos_init` sets its runtime through a OnceCell and the SQLite
// handle lives for the life of the process. Quitting and reopening is the whole
// point of the step.
//
// The directory is a mktemp -d, never the real Application Support path, so this
// cannot touch the user's own tags, connections or settings.
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

func expectFalse(_ actual: Bool, _ name: String) {
    if !actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected false") }
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

// The connection id is opaque to the tag store. A fixed string keeps the two
// processes talking about the same connection.
let CONN = "conn-step5"
let NOTE = "from the phase 1 check"

// MARK: - Phase one: write

/// Prove the write path through the FFI, and that a refusal arrives as the
/// core's own message.
func writePhase() {
    // A fresh directory: the label palette is global and must start empty, or a
    // later count would be measuring leftovers.
    attempt("a fresh store holds no labels") {
        expectEqual(try PharosCore.loadTagLabels().count, 0, "a fresh store holds no labels")
    }

    var label: TagLabel?
    attempt("create a label") {
        let made = try PharosCore.createTagLabel(CreateTagLabel(name: "Check", colorIndex: 1))
        label = made
        expectEqual(made.name, "Check", "the created label keeps its name")
        expectEqual(made.colorIndex, 1, "the created label keeps its colour index")
        expectFalse(made.id.isEmpty, "the core assigned an id")
        expectFalse(made.createdAt.isEmpty, "the core assigned a created timestamp")
    }
    guard let label else {
        fail("write phase", "no label to tag with; the rest of the phase cannot run")
        return
    }

    attempt("a new label carries no tags") {
        expectEqual(try PharosCore.countTags(forLabel: label.id), 0, "a new label carries no tags")
    }

    // Two keys for one row: this is the pk-plus-unique pair that lets a later
    // result match the tag through whichever candidate it carries.
    let upsert = UpsertRowTag(
        connectionId: CONN,
        labelId: label.id,
        note: NOTE,
        primaryKind: "pk",
        tableKey: "oid:16543",
        tableDisplay: "tagtest.users",
        identityColumns: ["id"],
        identityValues: ["1"],
        keys: [RowTagKey(identityKind: "pk", identityValue: "V1:1"),
               RowTagKey(identityKind: "unique", identityValue: "V6:a@b.co")]
    )
    attempt("write a tag") {
        let tag = try PharosCore.upsertRowTag(upsert)
        expectEqual(tag.keys.count, 2, "the stored tag holds both candidate keys")
        expectEqual(tag.note, NOTE, "the stored tag keeps its note")
        expectEqual(tag.labelId, label.id, "the stored tag names its label")
        expectEqual(tag.identityValues, ["1"], "the stored tag keeps its identity values")
        expectFalse(tag.id.isEmpty, "the core assigned a tag id")
    }

    attempt("read the tag back in the same process") {
        let tags = try PharosCore.loadRowTags(connectionId: CONN)
        expectEqual(tags.count, 1, "one tag loads back")
        expectEqual(tags.first?.keys.count, 2, "the loaded tag still holds both keys")
    }

    attempt("the label now counts one tag") {
        expectEqual(try PharosCore.countTags(forLabel: label.id), 1, "the label now counts one tag")
    }

    // MARK: A real core failure

    // The database enforces the parent-child invariant, so a tag naming a label
    // that does not exist is refused. This is the case the FFI reports as
    // {"error": "..."} on its ONE return channel.
    //
    // `upsertRowTag` goes through `callSync`, so this is the live proof that the
    // shared check reports the core's own message. Before it, the failure came
    // back as a decoding complaint that quoted the error object.
    var orphan = upsert
    orphan.labelId = "no-such-label"
    do {
        let tag = try PharosCore.upsertRowTag(orphan)
        fail("a tag naming an unknown label is refused",
             "it was accepted and stored as \(tag.id)")
    } catch let error as PharosCoreError {
        switch error {
        case .rustError(let message):
            expectFalse(message.isEmpty, "the refusal carries a message")
            // The whole point of the shared check: the message is the core's, so
            // it must not be the decode complaint or the raw error object.
            expectFalse(message.hasPrefix("{"), "the message is not the raw error object")
            expectFalse(message.hasPrefix("Failed to decode"),
                        "the message is not a decode complaint")
            print("  (the core said: \(message))")
        case .decodingError(let json, _):
            fail("a refusal arrives as rustError, not decodingError",
                 "got a decode complaint over: \(json.prefix(120))")
        case .nullResult:
            fail("a refusal arrives as rustError", "got nullResult")
        }
    } catch {
        fail("a refusal arrives as PharosCoreError", "got \(error)")
    }

    // A refused write must leave nothing behind, or the count above was measuring
    // a partial row.
    attempt("the refused write stored nothing") {
        expectEqual(try PharosCore.countTags(forLabel: label.id), 1,
                    "the refused write stored nothing")
        expectEqual(try PharosCore.loadRowTags(connectionId: CONN).count, 1,
                    "the refused write added no tag")
    }

    // MARK: A negative answer that is NOT a failure

    // These are the two wrappers that used to turn a core failure into `false`.
    // Here the answer is a genuine false — no row had that id — and it must come
    // back as false rather than throwing.
    attempt("deleting an unknown tag answers false") {
        expectFalse(try PharosCore.deleteRowTag(id: "no-such-tag"),
                    "deleting an unknown tag answers false")
    }
    attempt("deleting an unknown label answers false") {
        expectFalse(try PharosCore.deleteTagLabel(id: "no-such-label"),
                    "deleting an unknown label answers false")
    }
    attempt("a bulk delete of unknown ids counts zero") {
        expectEqual(try PharosCore.deleteRowTags(ids: ["no-such-tag", "nor-this"]), 0,
                    "a bulk delete of unknown ids counts zero")
    }

    // MARK: - Store mutations (Phase 3): compose -> upsert -> index
    //
    // `TagStore` is `@MainActor`. This binary is single-threaded and this is its
    // one and only (main) thread, so `MainActor.assumeIsolated` is safe here — see
    // the same note in PharosTests/TagStoreTests.swift.
    MainActor.assumeIsolated {
        let store = TagStore.shared

        var storeLabel: TagLabel?
        attempt("create a label through the store") {
            storeLabel = try store.createLabel(name: "StoreCheck")
        }
        guard let storeLabel else {
            fail("store mutations", "no label to tag with; the rest of the block cannot run")
            return
        }
        expectTrue(store.labels.contains { $0.id == storeLabel.id }, "createLabel refreshes labels")

        let storeIdentity = RowIdentity(tableKey: "oid:777", tableDisplay: "t.store",
                                        tableKeys: ["oid:777"],
                                        candidates: [KeySet(kind: "pk", keyColumns: ["id"],
                                                            keys: ["V1:9"])])
        guard case .success(let upsert) = TagComposer.upsert(
            row: 0, columns: ["id", "v"], rowValues: ["9", "x"],
            identity: storeIdentity, connectionId: "conn-store", labelId: storeLabel.id, note: "n"
        ) else {
            fail("store mutations", "TagComposer.upsert did not compose the fixture row")
            return
        }

        var storeTagId: String?
        attempt("upsertTag writes through the store") {
            storeTagId = try store.upsertTag(upsert).id
        }
        guard let storeTagId else {
            fail("store mutations", "no saved tag id; the rest of the block cannot run")
            return
        }
        let storeIndex = store.index(for: "conn-store")
        let storeKey = TagMatcher.compositeKey(tableKey: "oid:777", kind: "pk", value: "V1:9")
        expectEqual(storeIndex[storeKey]?.id, storeTagId, "upsertTag lands in the index under its key")

        attempt("removeTags deletes through the store") {
            try store.removeTags(ids: [storeTagId], connectionId: "conn-store")
        }
        expectTrue(store.index(for: "conn-store").isEmpty, "removeTags empties the index")

        // The "StoreCheck" label is left behind on purpose: the read phase counts
        // and deletes it, the same way it tears down "Check".
    }
}

// MARK: - Phase two: read, in a new process

/// Prove the tag survived the process exit, then prove the cascade.
func readPhase() {
    var label: TagLabel?
    // The write phase's store-mutation block (Phase 3) left "StoreCheck" behind
    // on purpose, so the palette now holds two labels, not one.
    var storeCheckLabel: TagLabel?
    attempt("the label survived the restart") {
        let labels = try PharosCore.loadTagLabels()
        expectEqual(labels.count, 2, "both labels survived the restart")
        expectEqual(labels.first?.name, "Check", "the label kept its name across the restart")
        label = labels.first
        storeCheckLabel = labels.first { $0.name == "StoreCheck" }
    }

    attempt("the tag survived the restart") {
        let tags = try PharosCore.loadRowTags(connectionId: CONN)
        expectEqual(tags.count, 1, "the tag survived the restart")
        expectEqual(tags.first?.note, NOTE, "the tag kept its note across the restart")
        expectEqual(tags.first?.keys.count, 2, "the tag kept both keys across the restart")
        expectEqual(tags.first?.tableDisplay, "tagtest.users",
                    "the tag kept its table display across the restart")
    }

    guard let label else {
        fail("read phase", "no label loaded; the cascade cannot be checked")
        return
    }

    attempt("the surviving label still counts its tag") {
        expectEqual(try PharosCore.countTags(forLabel: label.id), 1,
                    "the surviving label still counts its tag")
    }

    // Clean up the store-mutation label the write phase left behind, the same
    // way "Check" is cleaned up below — so the final count comes back to zero.
    guard let storeCheckLabel else {
        fail("read phase", "the StoreCheck label from the write phase is missing")
        return
    }
    attempt("deleting the store-check label answers true") {
        expectTrue(try PharosCore.deleteTagLabel(id: storeCheckLabel.id),
                   "deleting the store-check label answers true")
    }

    // Deleting a label is a CASCADE: the tag and its key rows go too. This is the
    // loss the caller must warn about, so it has to be real.
    attempt("deleting the label answers true") {
        expectTrue(try PharosCore.deleteTagLabel(id: label.id), "deleting the label answers true")
    }
    attempt("the cascade took the tag") {
        expectEqual(try PharosCore.loadRowTags(connectionId: CONN).count, 0,
                    "the cascade took the tag")
        expectEqual(try PharosCore.loadTagLabels().count, 0, "the label is gone")
    }
}

// MARK: - Entry

func runTests() {
    let args = CommandLine.arguments
    guard args.count >= 3, args[1] == "write" || args[1] == "read" else {
        print("usage: \(args.first ?? "binary") <write|read> <app-data-dir>")
        print("Run it through scripts/test-row-tag-ffi.sh, which supplies a temp directory.")
        exit(2)
    }
    let phase = args[1]
    let dir = args[2]

    guard dir.withCString({ pharos_init($0) }) else {
        print("FAIL pharos_init(\(dir)) returned false")
        exit(1)
    }
    print("--- \(phase) phase, store at \(dir) ---")

    if phase == "write" { writePhase() } else { readPhase() }

    pharos_shutdown()

    if failures == 0 {
        print("\nAll row tag FFI \(phase)-phase checks passed.")
    } else {
        print("\n\(failures) failure(s) in the \(phase) phase.")
        exit(1)
    }
}
