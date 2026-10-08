// Standalone test for CardDocument. Compiled by scripts/test-card-document.sh.
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

private func rows(_ n: Int) -> CardRunOutcome {
    .success(summary: .rows(count: n, hasMore: false), finishedAt: t0, executionTimeMs: 5, historyResultId: "h\(n)")
}

/// A document with one card holding `sql`.
private func doc(_ sql: String) -> (CardDocument, String) {
    var d = CardDocument()
    let id = d.cards[0].id
    _ = d.updateSQL(cardId: id, sql)
    return (d, id)
}

private func testNewDocument() {
    let d = CardDocument()
    expect(d.cards.count == 1, "new: one draft card")
    let c = d.cards[0]
    expect(c.version == 1 && c.lineageId == c.id, "new: version 1, its own lineage")
    expect(c.lastRun == nil && !c.isLocked && c.sql.isEmpty && c.kind == .sql, "new: a blank, unlocked SQL draft")
    expect(d.focusedCardId == c.id, "new: the draft has focus")
}

private func testFirstRunReplacesInPlace() {
    var (d, a) = doc("SELECT 1")
    let ticket = d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!
    expect(!ticket.splits, "first run: a draft never splits")
    let effect = d.completeRun(ticket, outcome: rows(1))
    expect(effect == .replaced(cardId: a), "first run: results go to the same card", "got \(effect)")
    let c = d.card(a)!
    expect(c.lastRun?.rawSQL == "SELECT 1" && c.lastRun?.renderedSQL == "SELECT 1", "first run: the run record keeps the SQL that ran")
    expect(c.colorIndex == 0, "first run: the first card gets the first colour", "got \(String(describing: c.colorIndex))")
    expect(!c.isLocked && d.cards.count == 1, "first run: nothing locks, no new card")
}

private func testRunWithoutEditReplaces() {
    var (d, a) = doc("SELECT 1")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!, outcome: rows(1))
    let ticket = d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT  1 ")!
    expect(!ticket.splits, "rerun: whitespace-only difference is not an edit")
    let effect = d.completeRun(ticket, outcome: rows(2))
    expect(effect == .replaced(cardId: a), "rerun: no edit replaces in place", "got \(effect)")
    expect(d.cards.count == 1 && d.card(a)?.lastRun?.historyResultId == "h2", "rerun: the new results replace the old")
}

private func testEditThenRunSplitsAndLocks() {
    var (d, a) = doc("SELECT * FROM users")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT * FROM users")!, outcome: rows(10))
    _ = d.rename(cardId: a, name: "Active users")
    _ = d.updateSQL(cardId: a, "SELECT * FROM users WHERE active")
    expect(d.isEdited(cardId: a, renderedSQL: "SELECT * FROM users WHERE active"), "split: the card reads as edited")
    d.expandedLineages.insert(d.card(a)!.lineageId)
    let ticket = d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT * FROM users WHERE active")!
    expect(ticket.splits, "split: an edited card with results splits")
    let effect = d.completeRun(ticket, outcome: rows(3))
    guard case let .split(locked, newId) = effect else {
        expect(false, "split: effect is .split", "got \(effect)"); return
    }
    expect(locked == a, "split: the old card keeps its id")
    let old = d.card(a)!, new = d.card(newId)!
    expect(old.isLocked && old.sql == "SELECT * FROM users", "split: the old card is locked and back to the SQL that ran")
    expect(old.lastRun?.historyResultId == "h10", "split: the old card keeps its results")
    expect(!new.isLocked && new.sql == "SELECT * FROM users WHERE active", "split: the new card has the edited SQL, unlocked")
    expect(new.lastRun?.historyResultId == "h3", "split: the new results belong to the new card")
    expect(new.lineageId == old.lineageId && new.version == 2, "split: the new card is version 2 of the same query")
    expect(new.name == "Active users", "split: the new card keeps the name")
    expect(d.cards.map(\.id) == [a, newId], "split: the new card goes below the old one")
    expect(d.focusedCardId == newId, "split: focus moves to the new card")
    expect(d.expandedLineages.isEmpty, "split: opened earlier versions fold again above the new run")
    expect(new.colorIndex != nil && new.colorIndex != old.colorIndex, "split: the new card gets its own colour")
}

private func testSplitGoesAfterTheLastVersion() {
    var (d, a) = doc("SELECT 1")
    let b = d.insertCard(after: a, sql: "SELECT 'other'")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!, outcome: rows(1))
    _ = d.updateSQL(cardId: a, "SELECT 2")
    guard case let .split(_, v2) = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 2")!, outcome: rows(2)) else {
        expect(false, "lineage order: first split"); return
    }
    _ = d.updateSQL(cardId: v2, "SELECT 3")
    guard case let .split(_, v3) = d.completeRun(d.beginRun(cardId: v2, mode: .run, renderedSQL: "SELECT 3")!, outcome: rows(3)) else {
        expect(false, "lineage order: second split"); return
    }
    expect(d.cards.map(\.id) == [a, v2, v3, b], "lineage order: versions stay together, the other card stays after them", "got \(d.cards.map(\.id))")
    expect(d.card(v3)?.version == 3, "lineage order: the third run is version 3")
}

private func testRunAndReplaceNeverSplits() {
    var (d, a) = doc("SELECT 1")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!, outcome: rows(1))
    _ = d.updateSQL(cardId: a, "SELECT 2")
    let ticket = d.beginRun(cardId: a, mode: .replace, renderedSQL: "SELECT 2")!
    expect(!ticket.splits, "replace: Run and Replace does not split")
    let effect = d.completeRun(ticket, outcome: rows(2))
    expect(effect == .replaced(cardId: a) && d.cards.count == 1, "replace: one card, results replaced", "got \(effect)")
    expect(!d.isEdited(cardId: a, renderedSQL: "SELECT 2"), "replace: the card no longer reads as edited")
}

private func testFailureAndCancelDoNotSplit() {
    var (d, a) = doc("SELECT 1")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!, outcome: rows(1))
    _ = d.updateSQL(cardId: a, "SELEC 2")
    var effect = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELEC 2")!, outcome: .failure(failureId: "f1"))
    expect(effect == .failed(cardId: a), "failure: effect is .failed", "got \(effect)")
    var c = d.card(a)!
    expect(d.cards.count == 1 && !c.isLocked && c.sql == "SELEC 2", "failure: no split, the edit stays")
    expect(c.lastFailureId == "f1" && c.lastRun?.historyResultId == "h1", "failure: the earlier results stay, the failure is noted")

    effect = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELEC 2")!, outcome: .cancelled)
    expect(effect == .cancelled(cardId: a) && d.cards.count == 1, "cancel: no split")

    _ = d.updateSQL(cardId: a, "SELECT 2")
    effect = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 2")!, outcome: rows(2))
    guard case .split = effect else { expect(false, "after failure: the next good run splits", "got \(effect)"); return }
    c = d.card(a)!
    expect(c.lastFailureId == nil || c.isLocked, "after failure: the locked card is the one with the old results")
}

private func testTypingDuringARun() {
    var (d, a) = doc("SELECT 1")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!, outcome: rows(1))
    _ = d.updateSQL(cardId: a, "SELECT 2")
    let ticket = d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 2")!
    _ = d.updateSQL(cardId: a, "SELECT 2 + 1")   // typed while it ran
    guard case let .split(_, b) = d.completeRun(ticket, outcome: rows(2)) else {
        expect(false, "typing: the run splits"); return
    }
    let new = d.card(b)!
    expect(new.sql == "SELECT 2 + 1", "typing: the new card keeps what the user typed during the run")
    expect(new.lastRun?.rawSQL == "SELECT 2", "typing: the new card's run record is the SQL that ran")
    expect(d.isEdited(cardId: b, renderedSQL: "SELECT 2 + 1"), "typing: so the new card reads as edited")

    // Typing during an unedited rerun: results replace, the typing stays.
    var (e, x) = doc("SELECT 1")
    _ = e.completeRun(e.beginRun(cardId: x, mode: .run, renderedSQL: "SELECT 1")!, outcome: rows(1))
    let t2 = e.beginRun(cardId: x, mode: .run, renderedSQL: "SELECT 1")!
    _ = e.updateSQL(cardId: x, "SELECT 9")
    expect(e.completeRun(t2, outcome: rows(4)) == .replaced(cardId: x), "typing on rerun: replaced in place")
    expect(e.card(x)?.sql == "SELECT 9" && e.isEdited(cardId: x, renderedSQL: "SELECT 9"), "typing on rerun: the typing stays and reads as edited")
}

private func testDeletedDuringARun() {
    var (d, a) = doc("SELECT 1")
    let b = d.insertCard(after: a, sql: "SELECT 2")
    let ticket = d.beginRun(cardId: b, mode: .run, renderedSQL: "SELECT 2")!
    _ = d.deleteCard(cardId: b)
    expect(d.completeRun(ticket, outcome: rows(2)) == .dropped, "deleted: a finished run for a deleted card is dropped")
    expect(d.cards.map(\.id) == [a], "deleted: nothing comes back")
}

private func testLockedCards() {
    var (d, a) = doc("SELECT 1")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!, outcome: rows(1))
    _ = d.updateSQL(cardId: a, "SELECT 2")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 2")!, outcome: rows(2))
    expect(!d.updateSQL(cardId: a, "DROP TABLE x"), "locked: edits are refused")
    expect(d.card(a)?.sql == "SELECT 1", "locked: the text does not change")
    // A rerun of the same SQL replaces its own results and keeps it locked.
    let t = d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!
    expect(d.completeRun(t, outcome: rows(5)) == .replaced(cardId: a), "locked: a rerun replaces in place")
    expect(d.card(a)?.isLocked == true && d.card(a)?.lastRun?.historyResultId == "h5", "locked: still locked, new results")
    // New variable values make the rendered SQL differ: that is an edit.
    let tv = d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1 /* new value */")!
    expect(tv.splits, "locked: changed variable values split")

    // Edit as New Card copies the text into the next version, unlocked.
    let copy = d.editAsNewCard(from: a)!
    let c = d.card(copy)!
    expect(!c.isLocked && c.sql == "SELECT 1" && c.lineageId == d.card(a)!.lineageId, "edit as new: an unlocked copy in the same query")
    expect(c.version == 3 && c.lastRun == nil, "edit as new: the next version, never run")
    expect(d.focusedCardId == copy, "edit as new: focus moves to the copy")
}

private func testRenameDeleteRestore() {
    var (d, a) = doc("SELECT 1")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!, outcome: rows(1))
    _ = d.updateSQL(cardId: a, "SELECT 2")
    guard case let .split(_, b) = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 2")!, outcome: rows(2)) else { return }
    expect(d.rename(cardId: b, name: "  Totals  "), "rename: accepted")
    expect(d.card(a)?.name == "Totals" && d.card(b)?.name == "Totals", "rename: every version of the query takes the trimmed name")
    expect(d.rename(cardId: b, name: "   ") && d.card(a)?.name == nil, "rename: a blank name clears it")

    // A suggested name lands only on a query nobody has named.
    expect(d.applySuggestedName(" Active users ", to: b) && d.card(a)?.name == "Active users" && d.card(b)?.nameIsSuggested == true,
           "suggest: an unnamed query takes the suggestion on every version")
    _ = d.rename(cardId: a, name: "Mine")
    expect(!d.applySuggestedName("Other", to: b) && d.card(b)?.name == "Mine" && d.card(b)?.nameIsSuggested == false,
           "suggest: a name the user gave always wins")

    let c = d.insertCard(after: b, sql: "SELECT 3")
    guard let removed = d.deleteCard(cardId: b) else { expect(false, "delete: returns the card"); return }
    expect(removed.index == 1 && d.cards.map(\.id) == [a, c], "delete: the card goes, its place is reported")
    expect(d.focusedCardId != b, "delete: focus leaves the deleted card")
    d.restoreCard(removed.card, at: removed.index)
    expect(d.cards.map(\.id) == [a, b, c], "restore: undo puts the card back where it was")

    // The last card can be deleted; the document keeps one blank draft.
    var single = CardDocument()
    _ = single.deleteCard(cardId: single.cards[0].id)
    expect(single.cards.count == 1 && single.cards[0].sql.isEmpty, "delete last: one blank draft remains")
}

private func testOnlySQLCardsRun() {
    let d = CardDocument(cards: [
        QueryCard(sql: "\\set x 1", kind: .psqlMeta),
        QueryCard(sql: "   ", kind: .sql),
    ])
    expect(d.beginRun(cardId: d.cards[0].id, mode: .run, renderedSQL: "\\set x 1") == nil, "run: a psql meta card does not run")
    expect(d.beginRun(cardId: d.cards[1].id, mode: .run, renderedSQL: "   ") == nil, "run: a blank card does not run")
}

private func testCodableRoundTrip() {
    var (d, a) = doc("SELECT 1")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!, outcome: rows(1))
    d.expandedLineages.insert(d.card(a)!.lineageId)
    let data = try! JSONEncoder().encode(d)
    let back = try! JSONDecoder().decode(CardDocument.self, from: data)
    expect(back == d, "codable: a document survives a JSON round trip")
}

private func testForReuse() {
    var (d, a) = doc("SELECT 1")
    _ = d.rename(cardId: a, name: "Q")
    _ = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 1")!, outcome: rows(1))
    _ = d.updateSQL(cardId: a, "SELECT 2")
    guard case .split = d.completeRun(d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT 2")!, outcome: rows(2)) else { return }
    let copy = d.forReuse()
    expect(copy.cards.count == 2, "reuse: same cards")
    expect(Set(copy.cards.map(\.id)).isDisjoint(with: Set(d.cards.map(\.id))), "reuse: fresh ids")
    expect(copy.cards[0].lineageId == copy.cards[1].lineageId && copy.cards[0].lineageId != d.cards[0].lineageId,
           "reuse: versions still share a new lineage")
    expect(copy.cards.allSatisfy { $0.lastRun == nil && $0.colorIndex == nil }, "reuse: no runs, no colours")
    expect(copy.cards[0].isLocked && copy.cards.map(\.sql) == ["SELECT 1", "SELECT 2"] && copy.cards[1].name == "Q",
           "reuse: locks, SQL and names stay")
    expect(copy.focusedCardId == copy.cards[1].id && copy.displayedCardId == nil, "reuse: focus follows, nothing displayed")
}

private func testRowsLoadedGrowsTheRunCount() {
    var (d, a) = doc("SELECT * FROM big")
    let first = d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT * FROM big")!
    _ = d.completeRun(first, outcome: .success(summary: .rows(count: 5000, hasMore: true), finishedAt: t0,
                                               executionTimeMs: 5, historyResultId: "h"))
    expect(d.rowsLoaded(cardId: a, runId: first.runId, count: 10000, hasMore: true),
           "rows loaded: Load More changes the count")
    expect(d.card(a)?.lastRun?.summary == .rows(count: 10000, hasMore: true), "rows loaded: the page's count, still more")
    _ = d.rowsLoaded(cardId: a, runId: first.runId, count: 12345, hasMore: false)
    expect(d.card(a)?.lastRun?.summary == .rows(count: 12345, hasMore: false), "rows loaded: Load All ends the '+'")
    expect(!d.rowsLoaded(cardId: a, runId: first.runId, count: 12345, hasMore: false), "rows loaded: no change, no write")
    expect(d.card(a)?.lastRun?.historyResultId == "h" && d.card(a)?.lastRun?.runId == first.runId,
           "rows loaded: the rest of the record stays")

    // A page that lands after the card ran again belongs to the old run.
    let second = d.beginRun(cardId: a, mode: .run, renderedSQL: "SELECT * FROM big")!
    _ = d.completeRun(second, outcome: rows(7))
    expect(!d.rowsLoaded(cardId: a, runId: first.runId, count: 99, hasMore: false), "rows loaded: a stale run is ignored")
    expect(d.card(a)?.lastRun?.summary == .rows(count: 7, hasMore: false), "rows loaded: the new run keeps its count")

    var (e, b) = doc("DELETE FROM t")
    let del = e.beginRun(cardId: b, mode: .run, renderedSQL: "DELETE FROM t")!
    _ = e.completeRun(del, outcome: .success(summary: .affected(3), finishedAt: t0, executionTimeMs: 1, historyResultId: nil))
    expect(!e.rowsLoaded(cardId: b, runId: del.runId, count: 9, hasMore: false), "rows loaded: an affected count stays")
    expect(!e.rowsLoaded(cardId: "missing", runId: del.runId, count: 9, hasMore: false), "rows loaded: unknown card")
}

func runTests() {
    testForReuse()
    testNewDocument()
    testFirstRunReplacesInPlace()
    testRunWithoutEditReplaces()
    testEditThenRunSplitsAndLocks()
    testSplitGoesAfterTheLastVersion()
    testRunAndReplaceNeverSplits()
    testFailureAndCancelDoNotSplit()
    testTypingDuringARun()
    testDeletedDuringARun()
    testLockedCards()
    testRenameDeleteRestore()
    testOnlySQLCardsRun()
    testCodableRoundTrip()
    testRowsLoadedGrowsTheRunCount()
    if failures == 0 { print("\nAll CardDocument tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
