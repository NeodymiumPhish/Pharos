// Standalone test runner for QueryResult.fromHistory — the sole path a history
// restore should use to rebuild a QueryResult, so no call site can forget
// `rowIdentity` and silently drop every tag on a reopened result.
// Compiled with the implementation by scripts/test-history-result.sh.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected true, got false")
    }
}

func expectNil<T>(_ actual: T?, _ name: String) {
    if actual == nil { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected nil, got \(String(describing: actual))")
    }
}

func expectNotNil<T>(_ actual: T?, _ name: String) {
    if actual != nil { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected non-nil, got nil")
    }
}

// MARK: - Fixtures

private func makeColumns() -> [ColumnDef] {
    [
        ColumnDef(name: "id", dataType: "int4", relationOid: 16543, relationAttno: 1),
        ColumnDef(name: "email", dataType: "text", relationOid: 16543, relationAttno: 2),
    ]
}

private func makeRows() -> [[AnyCodable]] {
    [
        [AnyCodable("1"), AnyCodable("ada@example.com")],
        [AnyCodable("2"), AnyCodable("grace@example.com")],
    ]
}

private func makeRowIdentity() -> RowIdentity {
    RowIdentity(
        tableKey: "16543",
        tableDisplay: "tagtest.users",
        tableKeys: ["16543"],
        candidates: [
            KeySet(kind: "pk", keyColumns: ["id"], keys: ["1", "2"]),
            KeySet(kind: "unique", keyColumns: ["email"], keys: ["ada@example.com", "grace@example.com"]),
        ]
    )
}

func runTests() {
    let columns = makeColumns()
    let rows = makeRows()
    let identity = makeRowIdentity()

    // MARK: 1 — rowIdentity survives whole, down to the candidates' keys.

    let withIdentity = QueryHistoryResultData(columns: columns, rows: rows, rowIdentity: identity)
    let result1 = QueryResult.fromHistory(withIdentity, historyEntryId: "hist-1", executionTimeMs: 42)

    expectNotNil(result1.rowIdentity, "a payload with rowIdentity gives a result with rowIdentity")
    if let ri = result1.rowIdentity {
        expectEqual(ri.tableKey, "16543", "tableKey survives")
        expectEqual(ri.tableDisplay, "tagtest.users", "tableDisplay survives")
        expectEqual(ri.tableKeys, ["16543"], "tableKeys survives")
        expectEqual(ri.candidates.count, 2, "both candidates survive")
        if ri.candidates.count == 2 {
            expectEqual(ri.candidates[0].kind, "pk", "candidate 0 kind survives")
            expectEqual(ri.candidates[0].keyColumns, ["id"], "candidate 0 keyColumns survives")
            expectEqual(ri.candidates[0].keys, ["1", "2"], "candidate 0 keys (per-row data) survives")
            expectEqual(ri.candidates[1].kind, "unique", "candidate 1 kind survives")
            expectEqual(ri.candidates[1].keyColumns, ["email"], "candidate 1 keyColumns survives")
            expectEqual(
                ri.candidates[1].keys,
                ["ada@example.com", "grace@example.com"],
                "candidate 1 keys (per-row data) survives"
            )
        }
    }

    // MARK: 2 — columns and rows survive.

    expectEqual(result1.columns.map(\.name), ["id", "email"], "column names survive")
    expectEqual(result1.columns.map(\.relationOid), [16543, 16543], "column relationOid survives")
    expectEqual(result1.rows.map { $0.map(\.stringValue) }, [["1", "ada@example.com"], ["2", "grace@example.com"]],
                "row values survive")

    // MARK: 3 — rowCount equals rows.count.

    expectEqual(result1.rowCount, 2, "rowCount equals rows.count")

    // MARK: 4 — historyEntryId and executionTimeMs come from the arguments, not the payload.

    expectEqual(result1.historyEntryId, "hist-1", "historyEntryId is the argument, not derived from the payload")
    expectEqual(result1.executionTimeMs, 42, "executionTimeMs is the argument, not derived from the payload")

    // A second call with different id/time values, same payload, must reflect
    // those different arguments — proving they aren't baked into the payload.
    let result1b = QueryResult.fromHistory(withIdentity, historyEntryId: "hist-2", executionTimeMs: 999)
    expectEqual(result1b.historyEntryId, "hist-2", "a different historyEntryId argument comes through unchanged")
    expectEqual(result1b.executionTimeMs, 999, "a different executionTimeMs argument comes through unchanged")

    // MARK: 5 — a nil rowIdentity in the payload stays nil, not an empty block.

    let withoutIdentity = QueryHistoryResultData(columns: columns, rows: rows, rowIdentity: nil)
    let result2 = QueryResult.fromHistory(withoutIdentity, historyEntryId: "hist-3", executionTimeMs: 7)
    expectNil(result2.rowIdentity, "a payload with nil rowIdentity gives a result with nil rowIdentity")

    print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) FAILED.")
    exit(failures == 0 ? 0 : 1)
}
