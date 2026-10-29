// Standalone test for WorkspaceResultPlacement. Compiled by
// scripts/test-workspace-result-placement.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private func meta(_ id: String, order: Int?, sql: String = "select 1",
                  cardId: String? = nil, hasResults: Bool = true,
                  status: String = QueryHistoryStatus.ok) -> WorkspaceResultMeta {
    var m = WorkspaceResultMeta(
        id: id, sql: sql, resultOrder: order, colorIndex: nil, customLabel: nil,
        rowCount: 1, columnCount: 1, schema: nil, tableNames: nil, hasResults: hasResults,
        executionTimeMs: 1, executedAt: "2026-10-29T00:00:00Z", chartViewStateJson: nil,
        rawSql: nil, lineStart: nil, lineEnd: nil)
    m.status = status
    m.cardId = cardId
    return m
}

private func document(_ cards: [(id: String, sql: String)]) -> CardDocument {
    CardDocument(cards: cards.map { QueryCard(id: $0.id, sql: $0.sql) })
}

private func kept(_ metas: [WorkspaceResultMeta], _ doc: CardDocument) -> [String] {
    WorkspaceResultPlacement.keptResultIds(of: metas, in: doc).sorted()
}

private func testNewestRunOfACardWins() {
    let doc = document([("a", "select 1"), ("b", "select 2")])
    let metas = [
        meta("r1", order: 0, cardId: "a"),
        meta("r2", order: 1, cardId: "b"),
        meta("r3", order: 2, cardId: "a"),
    ]
    expect(kept(metas, doc) == ["r2", "r3"], "newest per card", "\(kept(metas, doc))")
}

private func testResultOrderNotArrayOrder() {
    let doc = document([("a", "select 1")])
    let metas = [meta("new", order: 5, cardId: "a"), meta("old", order: 1, cardId: "a")]
    expect(kept(metas, doc) == ["new"], "ordered by resultOrder", "\(kept(metas, doc))")
}

private func testFailedRunsAreNotPlaced() {
    let doc = document([("a", "select 1")])
    let metas = [
        meta("ok", order: 0, cardId: "a"),
        meta("err", order: 1, cardId: "a", status: QueryHistoryStatus.error),
    ]
    expect(kept(metas, doc) == ["ok"], "a failure does not supersede a success", "\(kept(metas, doc))")
}

private func testNewestWithoutBlobStillSupersedes() {
    // The newest run kept no blob: the card shows "results removed", and the
    // older run's blob is still not needed.
    let doc = document([("a", "select 1")])
    let metas = [meta("old", order: 0, cardId: "a"), meta("new", order: 1, cardId: "a", hasResults: false)]
    expect(kept(metas, doc) == ["new"], "blobless newest still wins", "\(kept(metas, doc))")
}

private func testDeletedCardIsNotMatchedBySQL() {
    // The card the result names is gone; another card has the same SQL.
    let doc = document([("a", "select 1")])
    let metas = [meta("gone", order: 0, sql: "select 1", cardId: "deleted")]
    expect(WorkspaceResultPlacement.placements(of: metas, in: doc).isEmpty, "deleted card: no placement")
    expect(kept(metas, doc).isEmpty, "deleted card: no blob")
}

private func testResultWithoutCardIsNotPlaced() {
    // Recorded before cards existed: no cardId, even though the SQL matches.
    let doc = document([("a", "select 1")])
    let metas = [meta("legacy", order: 0, sql: "select 1")]
    expect(WorkspaceResultPlacement.placements(of: metas, in: doc).isEmpty, "no cardId: no placement")
    expect(kept(metas, doc).isEmpty, "no cardId: no blob")
}

private func testUnplacedNewerRunDoesNotSupersede() {
    // A newer result with the card's SQL but no card of its own leaves the
    // card's own result in place.
    let doc = document([("a", "select 1")])
    let metas = [
        meta("own", order: 0, cardId: "a"),
        meta("legacy", order: 1, sql: "select 1"),
        meta("gone", order: 2, sql: "select 1", cardId: "deleted"),
    ]
    expect(kept(metas, doc) == ["own"], "unplaced runs do not supersede", "\(kept(metas, doc))")
}

private func testPlacementsInResultOrder() {
    let doc = document([("a", "select 1"), ("b", "select 2")])
    let metas = [meta("r3", order: 3, cardId: "a"), meta("r1", order: 1, cardId: "b"), meta("r2", order: 2, cardId: "a")]
    let p = WorkspaceResultPlacement.placements(of: metas, in: doc)
    expect(p.map(\.meta.id) == ["r1", "r2", "r3"], "placements oldest first", "\(p.map(\.meta.id))")
    expect(p.map(\.cardId) == ["b", "a", "a"], "placements on the named cards", "\(p.map(\.cardId))")
}

func runTests() {
    testNewestRunOfACardWins()
    testResultOrderNotArrayOrder()
    testFailedRunsAreNotPlaced()
    testNewestWithoutBlobStillSupersedes()
    testDeletedCardIsNotMatchedBySQL()
    testResultWithoutCardIsNotPlaced()
    testUnplacedNewerRunDoesNotSupersede()
    testPlacementsInResultOrder()
    if failures == 0 { print("\nAll WorkspaceResultPlacement tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
