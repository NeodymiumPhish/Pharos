// Live runner for QueryVariableStore. Links the real Rust staticlib and
// writes a real SQLite file; it needs no PostgreSQL, because variables are
// local.
//
// The binary runs TWICE against one mktemp -d — the second process is what
// proves the write survived a restart, which is the "quit the app and open it
// again" of the manual check.
//
// The directory is never the real Application Support path, so this cannot
// touch the user's own variables, connections or settings.
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

/// The ids are fixed so the read process can check them without a side file.
let ipId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
let noteId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
let awkwardValue = "it's \"quoted\"\nand on two lines"

@MainActor
func writePhase() {
    let store = QueryVariableStore.shared
    do {
        try store.loadIfNeeded()
        expectEqual(store.variables.count, 0, "a fresh store starts empty")

        var posts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: QueryVariableStore.didChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.replace([
            QueryVariable(id: ipId, name: "target_ip", value: "10.0.0.1", type: .text),
            QueryVariable(id: noteId, name: "note", value: awkwardValue, type: .literal),
        ])
        expectEqual(posts, 1, "replace posts didChange once")
        expectEqual(store.variables.count, 2, "the cache holds both variables")
        expectEqual(store.definedNames, ["target_ip", "note"], "definedNames lists every non-empty name")

        // A re-read from the core within the same process sees the write.
        let stored = try PharosCore.loadQueryVariables()
        expectEqual(stored, store.variables, "the core stored exactly the cached list")
    } catch {
        failures += 1
        print("FAIL write phase threw \(error)")
    }
}

@MainActor
func readPhase() {
    let store = QueryVariableStore.shared
    do {
        try store.loadIfNeeded()
        expectEqual(store.variables.count, 2, "both variables survived the restart")
        expectEqual(store.variables.map(\.id), [ipId, noteId], "the order and the ids survived")
        expectEqual(store.variables.map(\.name), ["target_ip", "note"], "the names survived")
        expectEqual(store.variables.map(\.value), ["10.0.0.1", awkwardValue], "quote and newline survived")
        expectEqual(store.variables.map(\.type), [.text, .literal], "the types survived")

        store.replace([])
        expectEqual(try PharosCore.loadQueryVariables().isEmpty, true, "replace([]) clears the store")
        expectTrue(store.definedNames.isEmpty, "no names are defined after clearing")
    } catch {
        failures += 1
        print("FAIL read phase threw \(error)")
    }
}

func runTests() {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        print("usage: query-variable-store-tests <write|read> <dir>")
        exit(2)
    }
    args[2].withCString { pharos_init($0) }
    MainActor.assumeIsolated {
        if args[1] == "write" { writePhase() } else { readPhase() }
    }
    print(failures == 0 ? "\nAll QueryVariableStore checks passed" : "\n\(failures) FAILED")
    if failures > 0 { exit(1) }
}
