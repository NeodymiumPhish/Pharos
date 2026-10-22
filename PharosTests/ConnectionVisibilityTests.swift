// Standalone test for ConnectionVisibility — compiled by
// scripts/test-connection-visibility.sh.
import Foundation

private var failures = 0
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private let pg = ConnectionConfig(id: "pg", name: "Prod", host: "h", port: 5432, database: "d", username: "u")
private let pg2 = ConnectionConfig(id: "pg2", name: "Dev", host: "h", port: 5432, database: "d", username: "u")
private let savedFile = ConnectionConfig.duckDB(path: "/x/warehouse.duckdb", id: "wh", saved: true)
private let openedFile = ConnectionConfig.duckDB(path: "/x/sales.duckdb", id: "sales")
private let otherOpened = ConnectionConfig.duckDB(path: "/x/q3.duckdb", id: "q3")
private let openedMem = ConnectionConfig.duckDB(path: ":memory:", id: "mem")
private let all = [openedFile, pg, savedFile, otherOpened, pg2, openedMem]

private func sections(inUse: Set<String>, current: String?) -> [String] {
    ConnectionVisibility.popUpSections(all, inUse: inUse, current: current).map { group in
        let name: String
        switch group.section {
        case .openFiles: name = "open"
        case .postgres: name = "pg"
        case .duckdb: name = "duck"
        }
        return "\(name):" + group.records.map(\.id).joined(separator: ",")
    }
}

func runTests() {
    expect(ConnectionVisibility.listed(all).map(\.id), ["pg", "wh", "pg2"],
           "the lists of connections show saved records only, in the user's order")

    expect(sections(inUse: [], current: nil), ["pg:pg,pg2", "duck:wh"],
           "no tab uses an opened file: no Open Files group")
    expect(sections(inUse: ["sales", "mem", "pg"], current: nil), ["open:sales,mem", "pg:pg,pg2", "duck:wh"],
           "Open Files comes first and lists the opened records a tab uses, in the user's order")
    expect(sections(inUse: [], current: "q3"), ["open:q3", "pg:pg,pg2", "duck:wh"],
           "this tab's own opened record is always listed")
    expect(sections(inUse: ["wh"], current: "wh"), ["pg:pg,pg2", "duck:wh"],
           "a saved file in use stays in DuckDB, not Open Files")
    expect(ConnectionVisibility.popUpSections([openedFile], inUse: [], current: nil).count, 0,
           "an empty group is left out")

    expect(ConnectionVisibility.reorderedIds(saved: ["pg2", "wh", "pg"], all: all),
           ["pg2", "wh", "pg", "sales", "q3", "mem"],
           "a reorder in the manager: the hidden records follow in their old order")
    expect(ConnectionVisibility.reorderedIds(saved: ["pg", "new-stub"], all: [pg]), ["pg", "new-stub"],
           "an unsaved stub in the manager keeps its place")

    if failures == 0 { print("\nAll connection visibility tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
