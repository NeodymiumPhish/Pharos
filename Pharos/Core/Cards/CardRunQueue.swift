import Foundation

/// One editor tab's runs, one at a time.
///
/// Every card of a tab runs on the tab's one database connection, and a
/// connection runs one statement at a time, so a second run waits for the
/// first. Run All queues the cards in order as one batch; a failure or a
/// cancel in the batch stops the batch's remaining cards (a failed transaction
/// would make them fail anyway). Pure state: the coordinator starts what
/// `enqueue` and `finish` hand back.
struct CardRunQueue: Equatable {
    struct Job: Equatable {
        let id: String
        let cardId: String
        let mode: CardRunMode
        /// The Run All that queued this job, if any.
        let batchId: String?
    }

    enum EnqueueResult: Equatable {
        /// Nothing was running: start this job now.
        case startNow(Job)
        /// Another job runs: this one waits.
        case queued(Job)
        /// The card is already running or waiting.
        case alreadyQueued
    }

    enum Finish: Equatable { case succeeded, failed, cancelled }

    struct FinishResult: Equatable {
        /// The job to start now, if any.
        let next: Job?
        /// Cards of a stopped Run All that will not run.
        let stoppedCardIds: [String]
    }

    private(set) var running: Job?
    private(set) var waiting: [Job] = []

    func isRunning(cardId: String) -> Bool { running?.cardId == cardId }
    func isWaiting(cardId: String) -> Bool { waiting.contains { $0.cardId == cardId } }

    mutating func enqueue(cardId: String, mode: CardRunMode, batchId: String? = nil) -> EnqueueResult {
        guard !isRunning(cardId: cardId), !isWaiting(cardId: cardId) else { return .alreadyQueued }
        let job = Job(id: UUID().uuidString, cardId: cardId, mode: mode, batchId: batchId)
        if running == nil {
            running = job
            return .startNow(job)
        }
        waiting.append(job)
        return .queued(job)
    }

    /// Queue the cards in order as one Run All. Returns the job to start now,
    /// or nil when another job is running. A card already queued is skipped.
    mutating func enqueueBatch(cardIds: [String], mode: CardRunMode = .run) -> Job? {
        let batchId = UUID().uuidString
        var start: Job?
        for cardId in cardIds {
            if case let .startNow(job) = enqueue(cardId: cardId, mode: mode, batchId: batchId) { start = job }
        }
        return start
    }

    /// The running job ended. Returns what to start next and, for a failed or
    /// cancelled Run All, the cards it will no longer run.
    mutating func finish(jobId: String, _ how: Finish) -> FinishResult {
        guard let done = running, done.id == jobId else { return FinishResult(next: nil, stoppedCardIds: []) }
        running = nil
        var stopped: [String] = []
        if how != .succeeded, let batch = done.batchId {
            stopped = waiting.filter { $0.batchId == batch }.map(\.cardId)
            waiting.removeAll { $0.batchId == batch }
        }
        if !waiting.isEmpty { running = waiting.removeFirst() }
        return FinishResult(next: running, stoppedCardIds: stopped)
    }

    /// Take a waiting card out of the queue. False when it was not waiting
    /// (a running card is cancelled on the server, then finishes).
    @discardableResult
    mutating func cancelWaiting(cardId: String) -> Bool {
        guard let i = waiting.firstIndex(where: { $0.cardId == cardId }) else { return false }
        waiting.remove(at: i)
        return true
    }

    /// Drop every waiting job (tab closed, connection gone). The running job
    /// stays until it finishes. Returns the dropped jobs.
    mutating func cancelAll() -> [Job] {
        defer { waiting.removeAll() }
        return waiting
    }
}
