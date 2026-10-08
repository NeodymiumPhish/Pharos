// Standalone test for SessionSnapshot. Compiled by scripts/test-session-snapshot.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A document of `n` cards; the cards in `ran` have run.
private func doc(_ n: Int, ran: Set<Int>) -> CardDocument {
    var d = CardDocument(cards: (0..<n).map { QueryCard(sql: "SELECT \($0)") })
    for i in ran.sorted() {
        let id = d.cards[i].id
        let ticket = d.beginRun(cardId: id, mode: .run, renderedSQL: "SELECT \(i)")!
        _ = d.completeRun(ticket, outcome: .success(summary: .rows(count: i, hasMore: false), finishedAt: t0,
                                                    executionTimeMs: 1, historyResultId: nil))
    }
    return d
}

private func meta(_ runId: String, kind: StageSavedQueryResult.Kind = .rows, hasRows: Bool = true) -> SavedQueryResultMeta {
    SavedQueryResultMeta(id: "m-\(runId)", runId: runId, cardId: "old", kind: kind, sql: "SELECT 1", rawSql: nil,
                         schemaName: nil, executedAt: "2026-10-08T00:00:00Z", executionTimeMs: 1, rowsAffected: nil,
                         rowCount: 1, hasMore: false, chartViewStateJson: nil, hasRows: hasRows, compressedBytes: 1)
}

private func testPlanOrdersDisplayedThenNewest() {
    var d = doc(3, ran: [0, 1, 2])
    let ids = d.cards.map(\.id)
    d.displayedCardId = ids[0]
    let held = [
        SessionSnapshot.Held(cardId: ids[0], timestamp: t0),
        SessionSnapshot.Held(cardId: ids[1], timestamp: t0.addingTimeInterval(10)),
        SessionSnapshot.Held(cardId: ids[2], timestamp: t0.addingTimeInterval(20)),
    ]
    let plan = SessionSnapshot.plan(document: d, held: held, storedRunIds: [])
    expect(plan.stage.map(\.cardId) == [ids[0], ids[2], ids[1]], "plan: displayed first, then newest",
           "got \(plan.stage.map(\.cardId))")
    expect(plan.stage.map(\.priority) == [0, 1, 2], "plan: priorities in that order")
    expect(plan.stage.map(\.runId) == [ids[0], ids[2], ids[1]].map { id in d.card(id)!.lastRun!.runId },
           "plan: keyed by each card's run id")
    expect(plan.keep.isEmpty, "plan: nothing to keep on a first save")
}

private func testPlanKeepsStoredResultsNotInMemory() {
    let d = doc(3, ran: [0, 1, 2])
    let ids = d.cards.map(\.id)
    let runs = d.cards.map { $0.lastRun!.runId }
    let held = [SessionSnapshot.Held(cardId: ids[1], timestamp: t0)]
    let plan = SessionSnapshot.plan(document: d, held: held, storedRunIds: [runs[0], runs[1], "a-deleted-card's-run"])
    expect(plan.stage.map(\.cardId) == [ids[1]], "keep: the result in memory is written again")
    expect(plan.keep == [KeepSavedQueryResult(runId: runs[0], priority: 1)],
           "keep: the stored result no longer in memory stays, after the ones in memory",
           "got \(plan.keep)")
}

private func testPlanSkipsCardsWithoutARun() {
    let d = doc(2, ran: [1])
    let held = [SessionSnapshot.Held(cardId: d.cards[0].id, timestamp: t0)]
    let plan = SessionSnapshot.plan(document: d, held: held, storedRunIds: [])
    expect(plan.stage.isEmpty && plan.keep.isEmpty, "plan: a card that never ran has nothing to save")
}

private func testMatchByRunId() {
    let saved = doc(4, ran: [0, 1, 2, 3])
    let runs = saved.cards.map { $0.lastRun!.runId }
    let restored = saved.forRestore()
    let metas = [meta(runs[0]), meta(runs[1], hasRows: false), meta(runs[3], kind: .affected, hasRows: false)]
    let match = SessionSnapshot.match(document: restored, metas: metas)
    let ids = restored.cards.map(\.id)
    expect(match.results[ids[0]]?.runId == runs[0], "match: a stored result goes back on its card's new id")
    expect(match.results[ids[3]]?.kind == .affected, "match: an affected count has no rows and still matches")
    expect(match.removed == [ids[1], ids[2]], "match: rows dropped or never stored show as removed",
           "got \(match.removed)")
}

private func testLegacySessionHasNoRuns() {
    // A saved query from before Sessions opens with forReuse: no runs, so
    // nothing claims results it does not have.
    let restored = doc(2, ran: [0, 1]).forReuse()
    let match = SessionSnapshot.match(document: restored, metas: [])
    expect(match.results.isEmpty && match.removed.isEmpty, "legacy: no runs, nothing removed")
}

private func testCaption() {
    expect(SessionSnapshot.caption(resultCount: nil, bytes: nil) == nil, "caption: none without results")
    expect(SessionSnapshot.caption(resultCount: 0, bytes: 0) == nil, "caption: none for zero results")
    expect(SessionSnapshot.caption(resultCount: 1, bytes: 0) == "1 result", "caption: one result, no size")
    let two = SessionSnapshot.caption(resultCount: 2, bytes: 2_000_000) ?? ""
    expect(two.hasPrefix("2 results · ") && two.contains("MB"), "caption: count and size", "got \(two)")
}

func runTests() {
    testPlanOrdersDisplayedThenNewest()
    testPlanKeepsStoredResultsNotInMemory()
    testPlanSkipsCardsWithoutARun()
    testMatchByRunId()
    testLegacySessionHasNoRuns()
    testCaption()
    if failures == 0 { print("\nAll SessionSnapshot tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
