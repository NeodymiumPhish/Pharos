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

private func meta(_ id: String, order: Int?, sql: String = "select 1", rawSql: String? = nil,
                  cardId: String? = nil, hasResults: Bool = true,
                  status: String = QueryHistoryStatus.ok) -> WorkspaceResultMeta {
    var m = WorkspaceResultMeta(
        id: id, sql: sql, resultOrder: order, colorIndex: nil, customLabel: nil,
        rowCount: 1, columnCount: 1, schema: nil, tableNames: nil, hasResults: hasResults,
        executionTimeMs: 1, executedAt: "2026-10-29T00:00:00Z", chartViewStateJson: nil,
        rawSql: rawSql, lineStart: nil, lineEnd: nil)
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

private func testDeletedCardFallsBackToSQL() {
    let doc = document([("a", "select   1"), ("b", "select 2")])
    let metas = [
        meta("gone", order: 0, sql: "select 2", cardId: "deleted"),
        meta("legacy", order: 1, sql: "select 1"),
    ]
    let p = WorkspaceResultPlacement.placements(of: metas, in: doc)
    expect(p.map(\.cardId) == ["b", "a"], "deleted / missing card matched by SQL", "\(p.map(\.cardId))")
}

private func testSQLMatchUsesRawOrRendered() {
    let doc = document([("a", "select :x"), ("b", "select 5")])
    let byRaw = meta("raw", order: 0, sql: "select 3", rawSql: "select :x")
    let byRendered = meta("rendered", order: 1, sql: "select 5", rawSql: "select :y")
    let p = WorkspaceResultPlacement.placements(of: [byRaw, byRendered], in: doc)
    expect(p.map(\.cardId) == ["a", "b"], "raw or rendered SQL", "\(p.map(\.cardId))")
}

private func testFirstMatchingCard() {
    let doc = document([("a", "select 1"), ("b", "select 1")])
    let metas = [meta("r1", order: 0), meta("r2", order: 1)]
    expect(kept(metas, doc) == ["r2"], "SQL match takes the first card; newer wins", "\(kept(metas, doc))")
}

private func testUnmatchedResultIsDropped() {
    let doc = document([("a", "select 1")])
    let metas = [meta("orphan", order: 0, sql: "select 99", cardId: "deleted")]
    expect(kept(metas, doc).isEmpty, "no card, no blob")
    expect(WorkspaceResultPlacement.placements(of: metas, in: doc).isEmpty, "no card, no placement")
}

private func testSupersededByLegacyMatch() {
    // An id-matched result superseded by a newer SQL-matched one on the same card.
    let doc = document([("a", "select 1")])
    let metas = [meta("byId", order: 0, cardId: "a"), meta("bySQL", order: 1, sql: "select 1", cardId: "deleted")]
    expect(kept(metas, doc) == ["bySQL"], "mixed matching, newest wins", "\(kept(metas, doc))")
}

func runTests() {
    testNewestRunOfACardWins()
    testResultOrderNotArrayOrder()
    testFailedRunsAreNotPlaced()
    testNewestWithoutBlobStillSupersedes()
    testDeletedCardFallsBackToSQL()
    testSQLMatchUsesRawOrRendered()
    testFirstMatchingCard()
    testUnmatchedResultIsDropped()
    testSupersededByLegacyMatch()
    if failures == 0 { print("\nAll WorkspaceResultPlacement tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
