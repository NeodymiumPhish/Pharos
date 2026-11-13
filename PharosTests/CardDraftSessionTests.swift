// Standalone test for a card's "Describe the query" draft: CardDraftSession,
// CardDraftQueue and CardDraftStore. Compiled by scripts/test-card-draft-session.sh.
import Foundation

private var failures = 0
private var passes = 0

@MainActor
private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { passes += 1; print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private struct Boom: Error {}

/// A worker the test finishes by hand: it parks until `answer` or `fail`.
@MainActor
private final class Bench {
    var asked: [String] = []
    private var parked: [CheckedContinuation<CardDraftSession.Draft, Error>] = []
    var progress: (@MainActor (String) -> Void)?
    var cancelled = 0

    var worker: CardDraftSession.Worker {
        { [self] request, progress in
            asked.append(request)
            self.progress = progress
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { parked.append($0) }
            } onCancel: {
                Task { @MainActor in
                    self.cancelled += 1
                    self.fail(CancellationError())
                }
            }
        }
    }

    func answer(_ sql: String) {
        guard !parked.isEmpty else { return }
        parked.removeFirst().resume(returning: .init(sql: sql, note: "Reads t."))
    }

    func fail(_ error: Error) {
        guard !parked.isEmpty else { return }
        parked.removeFirst().resume(throwing: error)
    }

    func session(tab: String = "tab", queue: CardDraftQueue, timeout: Duration = .seconds(30)) -> CardDraftSession {
        CardDraftSession(tabId: tab, queue: queue, timeout: { timeout }, timeoutMessage: "too slow",
                         describe: { _ in "it failed" }, worker: worker)
    }
}

/// Let the tasks that are ready run.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(5))
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func testDraftsAndAnswers() async {
    let bench = Bench()
    let s = bench.session(queue: CardDraftQueue())
    var changes = 0
    s.onChange = { changes += 1 }
    expect(!s.start() && s.phase == .editing, "start: nothing to ask, nothing starts")
    s.request = "  orders per region \n"
    expect(s.start() && s.phase == .waiting, "start: asked, and in line")
    await settle()
    expect(s.phase == .drafting(progress: ""), "start: its turn comes", "\(s.phase)")
    expect(bench.asked == ["orders per region"], "start: the request is trimmed", "\(bench.asked)")
    bench.progress?("Writing the query…")
    expect(s.phase == .drafting(progress: "Writing the query…"), "progress: the step is named")
    bench.answer("SELECT 1")
    await settle()
    guard case let .ready(draft) = s.phase else { expect(false, "answer: the draft is ready", "\(s.phase)"); return }
    expect(draft.sql == "SELECT 1", "answer: the draft is ready")
    expect(changes >= 4, "every phase change is announced", "\(changes)")
    bench.progress?("late")
    expect(s.phase == .ready(draft), "progress after the answer changes nothing")

    s.request = "orders per region" // what was asked, trimmed: still a new text
    expect(s.phase == .editing, "editing the request drops the answer")
    s.request = "something else"
    expect(s.retry() && s.request == "orders per region", "retry asks the last question again")
    await settle()
    bench.fail(Boom())
    await settle()
    expect(s.phase == .failed("it failed"), "a failure is said in a sentence", "\(s.phase)")
    s.request = "orders"
    expect(s.phase == .editing, "editing the request drops the failure")
}

@MainActor
private func testMinimizedDraftGoesOn() async {
    let bench = Bench()
    let s = bench.session(queue: CardDraftQueue())
    s.request = "q"
    s.start()
    await settle()
    var changes = 0
    s.onChange = { changes += 1 }
    s.isOpen = false
    expect(changes == 1 && s.phase.isWorking, "minimize: announced, and the draft goes on")
    bench.answer("SELECT 2")
    await settle()
    if case .ready = s.phase { expect(true, "minimize: the answer waits in the session") }
    else { expect(false, "minimize: the answer waits in the session", "\(s.phase)") }
}

@MainActor
private func testStop() async {
    let bench = Bench()
    let queue = CardDraftQueue()
    let s = bench.session(queue: queue)
    s.request = "q"
    s.start()
    await settle()
    s.stop()
    expect(s.phase == .editing && s.request == "q", "stop: back to editing, the request kept")
    await settle()
    expect(bench.cancelled == 1, "stop: the worker's task is cancelled", "\(bench.cancelled)")
    bench.answer("SELECT late")
    await settle()
    expect(s.phase == .editing, "stop: a late answer is ignored")

    // The queue is free again: the next draft gets its turn.
    s.start()
    await settle()
    expect(s.phase == .drafting(progress: ""), "stop: the queue is released", "\(s.phase)")
    s.stop()
    await settle()
}

@MainActor
private func testOneAtATime() async {
    let queue = CardDraftQueue()
    let a = Bench(), b = Bench(), c = Bench()
    let sa = a.session(queue: queue), sb = b.session(queue: queue), sc = c.session(queue: queue)
    for s in [sa, sb, sc] { s.request = "q"; s.start() }
    await settle()
    expect(sa.phase == .drafting(progress: "") && sb.phase == .waiting && sc.phase == .waiting,
           "queue: one drafts, the others wait", "\(sa.phase) \(sb.phase) \(sc.phase)")
    expect(queue.waitingCount == 2, "queue: two in line")

    // A waiting draft that is stopped leaves the line without taking a turn.
    sb.stop()
    await settle()
    expect(queue.waitingCount == 1 && b.asked.isEmpty, "queue: a stopped waiter leaves the line")

    a.answer("SELECT a")
    await settle()
    expect(sc.phase == .drafting(progress: ""), "queue: the next in line starts", "\(sc.phase)")
    c.answer("SELECT c")
    await settle()
    expect(queue.waitingCount == 0, "queue: empty at the end")
    sb.start()
    await settle()
    expect(sb.phase == .drafting(progress: ""), "queue: free for the next draft", "\(sb.phase)")
    sb.stop()
    await settle()
}

@MainActor
private func testTimeout() async {
    let queue = CardDraftQueue()
    let slow = Bench(), behind = Bench()
    let first = slow.session(queue: queue, timeout: .milliseconds(60))
    let second = behind.session(queue: queue, timeout: .milliseconds(60))
    first.request = "q"; second.request = "q"
    first.start(); second.start()
    try? await Task.sleep(for: .milliseconds(140))
    await settle()
    expect(first.phase == .failed("too slow"), "timeout: the draft is stopped and says so", "\(first.phase)")
    expect(slow.cancelled == 1, "timeout: the worker's task is cancelled")
    // The second one's clock started at its turn, not at the press: it had
    // waited longer than the limit by then, and still drafts.
    expect(second.phase == .drafting(progress: "") || second.phase == .failed("too slow"),
           "timeout: the next draft got its turn", "\(second.phase)")
    expect(behind.asked == ["q"], "timeout: time in line is not counted against a draft")
    second.stop()
    await settle()
}

@MainActor
private func testStore() async {
    let queue = CardDraftQueue()
    let bench = Bench()
    let store = CardDraftStore()
    var changed: [String] = []
    store.onChange = { changed.append($0) }

    let s = bench.session(tab: "t1", queue: queue)
    store.add(s, for: "card1")
    expect(store.session(for: "card1") === s && changed == ["card1"], "store: add announces the card")
    s.request = "q"
    s.start()
    expect(changed.last == "card1" && changed.count == 2, "store: a session's change names its card", "\(changed)")
    await settle()

    changed = []
    store.move(from: "card1", to: "card2")
    expect(store.session(for: "card1") == nil && store.session(for: "card2") === s, "store: a split moves the draft")
    expect(changed == ["card1", "card2"], "store: both cards are refreshed", "\(changed)")
    changed = []
    bench.answer("SELECT 1")
    await settle()
    expect(changed == ["card2"], "store: a moved session announces its new card", "\(changed)")

    let other = Bench().session(tab: "t2", queue: queue)
    store.add(other, for: "card9")
    store.closeAll(exceptTabs: ["t1"])
    expect(store.session(for: "card9") == nil && store.session(for: "card2") != nil, "store: a closed tab takes its drafts")

    changed = []
    store.close("card2", notify: false)
    expect(store.isEmpty && changed.isEmpty, "store: a quiet close announces nothing")
    s.request = "again"
    expect(changed.isEmpty, "store: a closed session is no longer watched")

    let running = Bench()
    let r = running.session(queue: queue)
    store.add(r, for: "card3")
    r.request = "q"
    r.start()
    await settle()
    store.closeAll()
    await settle()
    expect(running.cancelled == 1 && store.isEmpty, "store: closing stops the draft")
    let after = Bench().session(queue: queue)
    after.request = "q"
    after.start()
    await settle()
    expect(after.phase == .drafting(progress: ""), "store: a closed draft frees the queue", "\(after.phase)")
    after.stop()
}

func runTests() {
    Task { @MainActor in
        await testDraftsAndAnswers()
        await testMinimizedDraftGoesOn()
        await testStop()
        await testOneAtATime()
        await testTimeout()
        await testStore()
        print("\n\(passes) passed, \(failures) failed")
        exit(failures > 0 ? 1 : 0)
    }
    dispatchMain()
}
