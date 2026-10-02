// Standalone test for CardRunQueue. Compiled by scripts/test-card-run-queue.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private func job(_ r: CardRunQueue.EnqueueResult) -> CardRunQueue.Job? {
    switch r {
    case let .startNow(j), let .queued(j): return j
    case .alreadyQueued: return nil
    }
}

private func testOneAtATime() {
    var q = CardRunQueue()
    let a = q.enqueue(cardId: "a", mode: .run)
    guard case let .startNow(ja) = a else { expect(false, "one at a time: the first job starts now", "got \(a)"); return }
    let b = q.enqueue(cardId: "b", mode: .run)
    guard case let .queued(jb) = b else { expect(false, "one at a time: the second job waits", "got \(b)"); return }
    expect(q.isRunning(cardId: "a") && q.isWaiting(cardId: "b"), "one at a time: a runs, b waits")
    expect(q.enqueue(cardId: "a", mode: .run) == .alreadyQueued, "dedup: a running card is not queued again")
    expect(q.enqueue(cardId: "b", mode: .replace) == .alreadyQueued, "dedup: a waiting card is not queued again")
    let f = q.finish(jobId: ja.id, .succeeded)
    expect(f.next == jb && f.stoppedCardIds.isEmpty, "one at a time: finishing a starts b")
    expect(q.isRunning(cardId: "b") && !q.isWaiting(cardId: "b"), "one at a time: b now runs")
    expect(q.finish(jobId: jb.id, .succeeded).next == nil && q.running == nil, "one at a time: the queue empties")
    expect(q.finish(jobId: "stale", .succeeded) == .init(next: nil, stoppedCardIds: []), "a stale finish does nothing")
}

private func testRunAllStopsAtFirstFailure() {
    var q = CardRunQueue()
    let first = q.enqueueBatch(cardIds: ["a", "b", "c"])
    expect(first?.cardId == "a", "run all: the first card starts")
    let other = job(q.enqueue(cardId: "x", mode: .run))!   // a single run queued during the batch
    expect(q.waiting.map(\.cardId) == ["b", "c", "x"], "run all: the rest wait in order")
    let f = q.finish(jobId: first!.id, .failed)
    expect(f.stoppedCardIds == ["b", "c"], "run all: a failure stops the batch's remaining cards", "got \(f.stoppedCardIds)")
    expect(f.next == other, "run all: a run that is not in the batch still goes")
}

private func testRunAllStopsOnCancel() {
    var q = CardRunQueue()
    let first = q.enqueueBatch(cardIds: ["a", "b"])!
    let f = q.finish(jobId: first.id, .cancelled)
    expect(f.stoppedCardIds == ["b"] && f.next == nil, "run all: a cancel stops the batch")
}

private func testRunAllSkipsCardsAlreadyQueued() {
    var q = CardRunQueue()
    _ = q.enqueue(cardId: "b", mode: .run)
    let first = q.enqueueBatch(cardIds: ["a", "b", "c"])
    expect(first == nil, "run all: nothing starts while another job runs")
    expect(q.waiting.map(\.cardId) == ["a", "c"], "run all: a card already queued is not queued twice", "got \(q.waiting.map(\.cardId))")
}

private func testCancelWaitingAndAll() {
    var q = CardRunQueue()
    _ = q.enqueue(cardId: "a", mode: .run)
    _ = q.enqueue(cardId: "b", mode: .run)
    _ = q.enqueue(cardId: "c", mode: .run)
    expect(q.cancelWaiting(cardId: "b"), "cancel waiting: a waiting card leaves the queue")
    expect(!q.cancelWaiting(cardId: "a"), "cancel waiting: the running card is not removed here")
    expect(q.waiting.map(\.cardId) == ["c"], "cancel waiting: the others keep their place")
    let dropped = q.cancelAll()
    expect(dropped.map(\.cardId) == ["c"] && q.waiting.isEmpty, "cancel all: every waiting job goes")
    expect(q.isRunning(cardId: "a"), "cancel all: the running job stays until it finishes")
}

func runTests() {
    testOneAtATime()
    testRunAllStopsAtFirstFailure()
    testRunAllStopsOnCancel()
    testRunAllSkipsCardsAlreadyQueued()
    testCancelWaitingAndAll()
    if failures == 0 { print("\nAll CardRunQueue tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
