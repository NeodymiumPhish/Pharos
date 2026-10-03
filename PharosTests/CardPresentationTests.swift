// Standalone test for CardPresentation. Compiled by scripts/test-card-presentation.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private func ran(_ sql: String, _ summary: CardRunRecord.Summary = .rows(count: 1420, hasMore: false)) -> QueryCard {
    var c = QueryCard(name: "Active users", sql: sql)
    c.lastRun = CardRunRecord(runId: "r", rawSQL: sql, renderedSQL: sql, finishedAt: Date(),
                              executionTimeMs: 45, summary: summary, historyResultId: "h")
    return c
}

private func make(_ card: QueryCard, position: Int = 1, versions: Int = 1, edited: Bool = false,
                  activity: CardActivity = .idle, inMemory: Bool = true, displayed: Bool = false) -> CardPresentation {
    CardPresentation.make(card: card, position: position, lineageCount: versions, isEdited: edited,
                          activity: activity, resultInMemory: inMemory, isDisplayed: displayed)
}

func runTests() {
    let draft = make(QueryCard(sql: "SELECT 1"))
    expect(draft.state == .draft && draft.badge == .init(text: "Not run", tone: .neutral), "draft: Not run badge")
    expect(draft.resultsButton == nil && draft.canRun && !draft.showsRunAndReplace, "draft: Run only")
    expect(draft.title == "Untitled query" && draft.titleIsPlaceholder, "draft: placeholder title")

    let has = make(ran("SELECT 1"))
    expect(has.state == .hasResults && has.badge == nil, "results: no badge")
    expect(has.resultsButton == .init(title: "View Results", detail: "1,420 rows", isShowing: false, isError: false),
           "results: View Results with the row count", "got \(String(describing: has.resultsButton))")
    expect(!has.showsRunAndReplace, "results: no Run and Replace until an edit")

    let showing = make(ran("SELECT 1"), displayed: true)
    expect(showing.resultsButton?.title == "Showing Results" && showing.resultsButton?.isShowing == true, "displayed: Showing Results")

    let more = make(ran("SELECT 1", .rows(count: 1000, hasMore: true)))
    expect(more.resultsButton?.detail == "1,000+ rows", "results: a cut result shows +")
    let one = make(ran("SELECT 1", .rows(count: 1, hasMore: false)))
    expect(one.resultsButton?.detail == "1 row", "results: singular row")
    let stmt = make(ran("UPDATE t SET x = 1", .affected(4882)))
    expect(stmt.resultsButton?.detail == "4,882 rows affected", "statement: rows affected", "got \(String(describing: stmt.resultsButton?.detail))")

    let edited = make(ran("SELECT 1"), edited: true)
    expect(edited.state == .edited && edited.badge == .init(text: "Edited since run", tone: .caution), "edited: caution badge")
    expect(edited.showsRunAndReplace && edited.resultsButton?.title == "View Results", "edited: Run and Replace shows; results still reachable")

    var failedCard = ran("SELECT 1")
    failedCard.lastFailureId = "f"
    let failed = make(failedCard)
    expect(failed.state == .failed && failed.resultsButton == .init(title: "View Error", detail: nil, isShowing: false, isError: true),
           "failed: View Error")

    var removedCard = ran("SELECT 1")
    removedCard.resultsRemoved = true
    let removed = make(removedCard)
    expect(removed.state == .resultsRemoved && removed.resultsButton == nil, "removed: no results button")
    expect(removed.badge == .init(text: "Results removed", tone: .neutral), "removed: badge")
    expect(make(ran("SELECT 1"), inMemory: false).state == .resultsRemoved, "removed: a run with no rows in memory reads as removed")

    let running = make(ran("SELECT 1"), activity: .running(startedAt: Date()))
    expect(running.state == .running && running.showsCancel && !running.canRun, "running: Cancel, no Run")
    let waiting = make(QueryCard(sql: "SELECT 1"), activity: .waiting)
    expect(waiting.state == .waiting && waiting.badge == .init(text: "Waiting", tone: .neutral) && waiting.showsCancel, "waiting: badge and Cancel")

    var locked = ran("SELECT 1")
    locked.isLocked = true
    locked.version = 1
    let lockedP = make(locked, position: 3, versions: 2)
    expect(lockedP.isLocked && lockedP.versionChip == "v1", "locked: lock and version chip")
    expect(lockedP.canRun, "locked: a locked card can still run its own SQL")
    expect(make(ran("SELECT 1"), versions: 1).versionChip == nil, "version chip only when the query has versions")

    let meta = make(QueryCard(sql: "\\set x 1", kind: .psqlMeta))
    expect(meta.state == .notRunnable && !meta.canRun && meta.badge?.text == "psql command", "psql meta: cannot run")

    expect(lockedP.accessibilityLabel == "Card 3, Active users, version 1, locked, has results",
           "accessibility: position, name, version, lock, state", "got \(lockedP.accessibilityLabel)")
    expect(make(QueryCard(sql: "x"), position: 2).accessibilityLabel == "Card 2, Untitled query, not run",
           "accessibility: draft", "got \(make(QueryCard(sql: "x"), position: 2).accessibilityLabel)")

    if failures == 0 { print("\nAll CardPresentation tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
