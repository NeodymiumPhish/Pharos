// Live runner for saved Session results. Links the real Rust staticlib and
// writes a real SQLite file in a temporary directory (never the real
// Application Support path); needs no PostgreSQL. Compiled by
// scripts/test-session-store.sh.
import Foundation
import CPharosCore

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private let columns = [
    ColumnDef(name: "id", dataType: "int4", relationOid: 16543, relationAttno: 1),
    ColumnDef(name: "note", dataType: "text"),
]
private let rows: [[AnyCodable]] = [
    [AnyCodable("1"), AnyCodable("it's \"quoted\"\nand on two lines")],
    [AnyCodable("2"), AnyCodable(nil)],
]
private let identity = RowIdentity(tableKey: "16543", tableDisplay: "public.t", tableKeys: ["16543"],
                                   candidates: [KeySet(kind: "pk", keyColumns: ["id"], keys: ["1", "2"])])

private func stage(_ session: String, _ snapshot: String, run: String, priority: Int,
                   kind: StageSavedQueryResult.Kind) -> StageSavedQueryResult {
    StageSavedQueryResult(
        savedQueryId: session, snapshotId: snapshot, runId: run, cardId: "card-\(run)", priority: priority,
        kind: kind, sql: "SELECT * FROM t", rawSql: "SELECT * FROM {{tbl}}", schemaName: "public",
        executedAt: "2026-10-08T12:00:00Z", executionTimeMs: 7,
        rowsAffected: kind == .affected ? 4 : nil, rowCount: kind == .rows ? 2 : nil, hasMore: kind == .rows,
        chartViewStateJson: kind == .rows ? "{\"viewMode\":\"chart\"}" : nil,
        columns: kind == .rows ? columns : nil, rows: kind == .rows ? rows : nil,
        rowIdentity: kind == .rows ? identity : nil)
}

private func commit(_ session: String, _ snapshot: String, keep: [KeepSavedQueryResult] = []) -> CommitSavedQuerySnapshot {
    CommitSavedQuerySnapshot(savedQueryId: session, snapshotId: snapshot, sql: "SELECT * FROM t;",
                             cardsJson: "{\"format\":1}", connectionId: "no-such-connection",
                             schemaName: "public", keep: keep)
}

func runTests() {
    let args = CommandLine.arguments
    guard args.count == 2 else { print("usage: session-store-tests <dir>"); exit(2) }
    args[1].withCString { pharos_init($0) }

    do {
        let created = try PharosCore.createSavedQuery(CreateSavedQuery(
            name: "S", folder: nil, sql: "SELECT 1", connectionId: nil, variables: nil))
        expect(!created.hasSavedResults && created.resultsSnapshotId == nil, "a new Session has no results")

        // First save: one result with rows, one affected count.
        let a = try PharosCore.stageSavedQueryResult(stage(created.id, "snap1", run: "runA", priority: 0, kind: .rows))
        expect(a.stored && a.compressedBytes > 0, "the rows are stored, compressed")
        let b = try PharosCore.stageSavedQueryResult(stage(created.id, "snap1", run: "runB", priority: 1, kind: .affected))
        expect(b.stored && b.compressedBytes == 0, "an affected count has no rows to store")
        let done = try PharosCore.commitSavedQuerySnapshot(commit(created.id, "snap1"))
        expect(done.droppedRunIds.isEmpty, "nothing dropped under the budget")
        expect(done.savedQuery.resultsSnapshotId == "snap1" && done.savedQuery.resultCount == 2,
               "the Session points at its snapshot", "got \(done.savedQuery)")
        expect(done.savedQuery.hasSavedResults, "the Session has saved results")
        expect(done.savedQuery.connectionId == nil, "an unknown connection id is stored as nil")
        expect(done.savedQuery.schemaName == "public" && done.savedQuery.cardsJson == "{\"format\":1}",
               "the commit stores the schema and the cards")

        let listed = try PharosCore.loadSavedQueries().first { $0.id == created.id }
        expect(listed?.resultsBytes == a.compressedBytes && listed?.resultsSavedAt != nil,
               "the list carries the size and the saved time")

        // Read back.
        let metas = try PharosCore.loadSavedQueryResults(savedQueryId: created.id)
        expect(metas.map(\.runId) == ["runA", "runB"], "metas in priority order", "got \(metas.map(\.runId))")
        let m = metas[0]
        expect(m.kind == .rows && m.hasRows && m.hasMore && m.rowCount == 2 && m.rawSql == "SELECT * FROM {{tbl}}",
               "the row result's metadata comes back", "got \(m)")
        expect(m.chartViewStateJson == "{\"viewMode\":\"chart\"}", "the chart state comes back")
        expect(metas[1].kind == .affected && metas[1].rowsAffected == 4 && !metas[1].hasRows,
               "the affected result's metadata comes back")

        if let data = try PharosCore.getSavedQueryResult(id: m.id) {
            let result = QueryResult.fromSavedSession(data, hasMore: m.hasMore, executionTimeMs: 7)
            expect(result.columns.map(\.name) == ["id", "note"] && result.columns[0].relationOid == 16543,
                   "columns round-trip")
            expect(result.rows.map { $0.map(\.stringValue) } == rows.map { $0.map(\.stringValue) },
                   "rows round-trip, quotes, newlines and nulls included")
            expect(result.rowIdentity?.candidates.first?.keys == ["1", "2"], "the row identity round-trips")
            expect(result.hasMore, "hasMore comes back")
        } else {
            failures += 1
            print("FAIL the stored rows did not come back")
        }
        expect(try PharosCore.getSavedQueryResult(id: metas[1].id) == nil, "no rows for an affected result")

        // A failed save leaves the stored snapshot.
        _ = try PharosCore.stageSavedQueryResult(stage(created.id, "snap2", run: "runC", priority: 0, kind: .rows))
        try PharosCore.abortSavedQuerySnapshot(savedQueryId: created.id, snapshotId: "snap2")
        expect(try PharosCore.loadSavedQueryResults(savedQueryId: created.id).map(\.runId) == ["runA", "runB"],
               "an aborted save leaves the stored snapshot")

        // A second save keeps a stored result that is not in memory.
        _ = try PharosCore.stageSavedQueryResult(stage(created.id, "snap3", run: "runD", priority: 0, kind: .rows))
        let again = try PharosCore.commitSavedQuerySnapshot(
            commit(created.id, "snap3", keep: [KeepSavedQueryResult(runId: "runA", priority: 1)]))
        expect(try PharosCore.loadSavedQueryResults(savedQueryId: created.id).map(\.runId) == ["runD", "runA"],
               "the second save holds the new result and the kept one")
        expect(again.savedQuery.resultCount == 2, "the count follows the new snapshot")

        // Deleting the Session deletes its results.
        _ = try PharosCore.deleteSavedQuery(id: created.id)
        expect(try PharosCore.loadSavedQueryResults(savedQueryId: created.id).isEmpty, "delete removes the results")
    } catch {
        failures += 1
        print("FAIL threw \(error)")
    }

    print(failures == 0 ? "\nAll Session store tests passed." : "\n\(failures) failure(s).")
    exit(failures == 0 ? 0 : 1)
}
