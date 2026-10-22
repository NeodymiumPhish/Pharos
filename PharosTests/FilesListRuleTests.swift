// Standalone test for FilesListRule — compiled by scripts/test-files-list-rule.sh.
import Foundation

private var failures = 0
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private let now = RecentFile.formatter.date(from: "2026-10-22T12:00:00Z")!
private func file(_ path: String, _ kind: String, daysAgo: Double) -> RecentFile {
    RecentFile(path: path, kind: kind, lastOpenedAt: RecentFile.stamp(now.addingTimeInterval(-daysAgo * 86_400)))
}

func runTests() {
    // The core's JSON, from a literal, so a mis-cased key fails.
    let json = #"[{"path":"/a/b.duckdb","kind":"duckdb","lastOpenedAt":"2026-10-22T16:02:00Z"}]"#
    let decoded = try? JSONDecoder().decode([RecentFile].self, from: Data(json.utf8))
    expect(decoded?.first?.lastOpened != nil, true, "the core's camelCase JSON decodes, with its time")

    let sales = ConnectionConfig.duckDB(path: "/d/sales.duckdb", id: "sales")
    let wh = ConnectionConfig.duckDB(path: "/d/warehouse.duckdb", id: "wh", saved: true)
    let mem = ConnectionConfig.duckDB(path: ":memory:", id: "mem")
    let closedMem = ConnectionConfig.duckDB(path: ":memory:", id: "mem2")
    let records = [sales, wh, mem, closedMem]
    let files = [
        file("/d/sales.duckdb", "duckdb", daysAgo: 0),
        file("/d/q3.csv", "data", daysAgo: 1),
        file("/d/warehouse.duckdb", "duckdb", daysAgo: 59),
        file("/d/old.parquet", "data", daysAgo: 61),
        file("/d/ancient.duckdb", "duckdb", daysAgo: 400),
    ]
    let byPath = Dictionary(uniqueKeysWithValues: records.filter { !$0.isInMemoryDuckDB }.map { ($0.database, $0) })
    let sections = FilesListRule.sections(files: files, records: records, openRecordIds: ["sales", "mem"],
                                          recordForPath: { byPath[$0] }, now: now)
    let shape = sections.map { s -> String in
        let name: String
        switch s.section { case .open: name = "open"; case .recent: name = "recent"; case .older: name = "older" }
        return name + ":" + s.rows.map(\.title).joined(separator: ",")
    }
    expect(shape, ["open:sales.duckdb,In-memory DuckDB", "recent:q3.csv,warehouse.duckdb",
                   "older:old.parquet,ancient.duckdb"],
           "Open (open records, then in-memory), Recent (60 days), Older; newest first")
    let open = sections[0].rows
    expect(open[0].isOpen && open[0].recordId == "sales" && !open[0].saved, true, "an opened file: its record, not saved")
    expect(open[1].kind, .memory, "an open in-memory database is a row of its own")
    expect(open[1].path, nil, "with no path")
    let recent = sections[1].rows
    expect(recent[0].kind, .data, "a CSV is a data file")
    expect(recent[0].recordId, nil, "a data file has no record")
    expect(recent[1].saved, true, "a saved file says so")
    expect(recent[1].folder, "/d", "the folder")
    expect(FilesListRule.sections(files: [], records: [closedMem], openRecordIds: [], recordForPath: { _ in nil }, now: now).count,
           0, "a closed in-memory database is not listed; empty sections are left out")
    let days59 = FilesListRule.sections(files: [file("/x.csv", "data", daysAgo: 59.9)], records: [], openRecordIds: [],
                                        recordForPath: { _ in nil }, now: now)
    expect(days59.first?.section, .recent, "just under 60 days is Recent")

    // Full forget: Remove from List deletes a not-saved record nothing holds.
    let salesRow = open[0], whRow = recent[1], csvRow = recent[0]
    expect(FilesListRule.forgetsRecord(salesRow, sessionConnectionIds: [], tabConnectionIds: []), true,
           "a not-saved file that nothing uses: its record goes too")
    expect(FilesListRule.forgetsRecord(salesRow, sessionConnectionIds: ["sales"], tabConnectionIds: []), false,
           "a saved Session uses it: only the entry goes")
    expect(FilesListRule.forgetsRecord(salesRow, sessionConnectionIds: [], tabConnectionIds: ["sales"]), false,
           "an open tab uses it: only the entry goes")
    expect(FilesListRule.forgetsRecord(whRow, sessionConnectionIds: [], tabConnectionIds: []), false,
           "a saved file keeps its connection")
    expect(FilesListRule.forgetsRecord(csvRow, sessionConnectionIds: [], tabConnectionIds: []), false,
           "a data file has no record to forget")

    if failures == 0 { print("\nAll files list rule tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
