import Foundation

// "Describe the query", per card: the state of one card's draft, the queue
// that runs one draft at a time, and the store that keeps every card's draft
// while its card is off screen, folded, or on another tab.
//
// Foundation only. What asks the model is handed in as a closure
// (`CardDraftSession.Worker`), so none of this knows about the pipeline, the
// views or the window.

// MARK: - Queue

/// Runs one draft at a time, first come first served.
///
/// The on-device model answers one request at a time and reports the rest as
/// busy, so a second card's draft waits its turn instead of failing.
@MainActor
final class CardDraftQueue {
    static let shared = CardDraftQueue()

    private var isBusy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// How many drafts wait behind the one that runs.
    var waitingCount: Int { waiters.count }

    /// Returns when it is the caller's turn. Every return must be matched by
    /// one `release()`. Throws `CancellationError`, and takes no turn, when
    /// the caller's task is cancelled while it waits.
    func acquire() async throws {
        try Task.checkCancellation()
        guard isBusy else {
            isBusy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.abandon(id) }
        }
    }

    /// Hand the turn to the next waiter, or free the queue.
    func release() {
        guard !waiters.isEmpty else {
            isBusy = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    /// A waiter whose task was cancelled leaves the line. One that already
    /// has the turn is not here any more: it sees the cancellation itself
    /// and releases.
    private func abandon(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

// MARK: - Session

/// One card's "Describe the query" draft: the words asked, where the draft
/// stands, and the task that asks the model.
///
/// It belongs to the card, not to the strip that shows it. The strip can be
/// hidden, the card folded or scrolled away, the tab or the window switched:
/// the draft keeps running and its answer waits here.
@MainActor
final class CardDraftSession {

    /// A finished draft, reviewed and ready to show.
    struct Draft: Equatable {
        /// The statement, cleaned.
        var sql: String
        /// What it reads, what to check and what Pharos corrected.
        var note: String
        /// The note names something to check before running.
        var noteIsCaution = false
        /// Set when the statement is not a plain read: Insert asks first.
        var warning: String?
        /// A digest of the description, for the feedback thumbs.
        var promptHash: String?
    }

    enum Phase: Equatable {
        /// Nothing asked yet, or the description changed since the answer.
        case editing
        /// Asked, and behind another card's draft.
        case waiting
        /// The model is working. `progress` names the step; empty at first.
        case drafting(progress: String)
        case ready(Draft)
        case failed(String)

        /// Waiting or drafting: there is a task to stop.
        var isWorking: Bool {
            switch self {
            case .waiting, .drafting: return true
            case .editing, .ready, .failed: return false
            }
        }
    }

    /// Asks the model. Called on the main actor when the draft's turn comes;
    /// `progress` takes the name of each step as it starts. Throws
    /// `CancellationError` when stopped.
    typealias Worker = @MainActor (_ description: String, _ progress: @escaping @MainActor (String) -> Void) async throws -> Draft

    /// The tab the card is in, so a closed tab takes its drafts with it.
    let tabId: String

    /// The words in the field. Changing them after an answer drops the
    /// answer: Insert must never put in SQL that answers a question the
    /// analyst has since rewritten.
    var request: String = "" {
        didSet {
            guard request != oldValue else { return }
            switch phase {
            case .ready, .failed: phase = .editing
            case .editing, .waiting, .drafting: break
            }
        }
    }

    private(set) var phase: Phase = .editing {
        didSet { if phase != oldValue { onChange?() } }
    }

    /// The strip shows. False is minimized: the draft goes on, and the
    /// card's Describe button says where it stands.
    var isOpen = true {
        didSet { if isOpen != oldValue { onChange?() } }
    }

    /// Called after `phase` or `isOpen` changes.
    var onChange: (() -> Void)?

    /// The words the last draft was asked for, so Retry asks the same
    /// question even after the field was edited and the edit abandoned.
    private(set) var lastAsked = ""

    private let worker: Worker
    private let timeout: () -> Duration
    private let describe: (Error) -> String
    private let timeoutMessage: String
    private let queue: CardDraftQueue

    private var task: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// Counts the drafts asked for and stopped. A task that finishes late
    /// (stopped, timed out, or replaced by a retry) finds a newer number and
    /// changes nothing.
    private var generation = 0

    /// - Parameters:
    ///   - queue: nil for the app's one queue.
    ///   - timeout: read when a draft starts running, so a change in
    ///     Settings applies to the next draft.
    ///   - describe: one sentence for a failure the worker throws.
    init(tabId: String, queue: CardDraftQueue? = nil,
         timeout: @escaping () -> Duration,
         timeoutMessage: String,
         describe: @escaping (Error) -> String,
         worker: @escaping Worker) {
        self.tabId = tabId
        self.queue = queue ?? .shared
        self.timeout = timeout
        self.timeoutMessage = timeoutMessage
        self.describe = describe
        self.worker = worker
    }

    /// Ask for a draft of `request`. False when there is nothing to ask.
    /// A draft already running is stopped first.
    @discardableResult
    func start() -> Bool {
        let asked = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return false }
        cancelWork()
        generation += 1
        let generation = self.generation
        lastAsked = asked
        phase = .waiting

        let queue = self.queue
        let worker = self.worker
        task = Task { @MainActor [weak self] in
            do {
                try await queue.acquire()
                defer { queue.release() }
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.phase = .drafting(progress: "")
                self.armTimeout(for: generation)
                let draft = try await worker(asked) { [weak self] progress in
                    guard let self, self.generation == generation, case .drafting = self.phase else { return }
                    self.phase = .drafting(progress: progress)
                }
                try Task.checkCancellation()
                self.finish(generation, .ready(draft))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.finish(generation, .failed(self.describe(error)))
            }
        }
        return true
    }

    /// Ask the last question again, of a model that has not seen its answer.
    @discardableResult
    func retry() -> Bool {
        if !lastAsked.isEmpty { request = lastAsked }
        return start()
    }

    /// Stop the draft that waits or runs. The description stays.
    func stop() {
        guard phase.isWorking else { return }
        cancelWork()
        phase = .editing
    }

    /// Stop everything; the session is going away.
    func invalidate() {
        cancelWork()
        onChange = nil
    }

    private func cancelWork() {
        generation += 1
        task?.cancel()
        task = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func finish(_ generation: Int, _ phase: Phase) {
        guard generation == self.generation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        task = nil
        self.phase = phase
    }

    /// The limit on one draft, counted from its turn, not from the press:
    /// time spent behind another card's draft is not the model being slow.
    private func armTimeout(for generation: Int) {
        let limit = timeout()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.generation == generation, self.phase.isWorking else { return }
            self.cancelWork()
            self.phase = .failed(self.timeoutMessage)
        }
    }
}

// MARK: - Store

/// Every card's draft, by card id, for one window.
///
/// The card views come and go (a tab switch drops them all); the drafts stay
/// here until their strip is closed, their card deleted or their tab closed.
@MainActor
final class CardDraftStore {
    private var sessions: [String: CardDraftSession] = [:]

    /// A card's draft changed, opened, closed or moved to another card.
    var onChange: ((_ cardId: String) -> Void)?

    var isEmpty: Bool { sessions.isEmpty }
    var cardIds: [String] { Array(sessions.keys) }

    func session(for cardId: String) -> CardDraftSession? { sessions[cardId] }

    /// Keep `session` as `cardId`'s draft, in place of any it had.
    func add(_ session: CardDraftSession, for cardId: String) {
        sessions[cardId]?.invalidate()
        sessions[cardId] = session
        watch(session, as: cardId)
        onChange?(cardId)
    }

    /// Stop and forget `cardId`'s draft. `notify: false` for a caller that
    /// is already refreshing the card.
    func close(_ cardId: String, notify: Bool = true) {
        guard let session = sessions.removeValue(forKey: cardId) else { return }
        session.invalidate()
        if notify { onChange?(cardId) }
    }

    /// Stop and forget every draft (the feature was switched off).
    func closeAll() {
        for id in cardIds { close(id) }
    }

    /// Stop and forget the drafts of tabs that are not in `tabIds`.
    func closeAll(exceptTabs tabIds: Set<String>) {
        for (id, session) in sessions where !tabIds.contains(session.tabId) { close(id) }
    }

    /// The draft of `old` now belongs to `new`: a run split the card, and
    /// the text being worked on went to the new version.
    func move(from old: String, to new: String) {
        guard old != new, let session = sessions.removeValue(forKey: old) else { return }
        sessions[new]?.invalidate()
        sessions[new] = session
        watch(session, as: new)
        onChange?(old)
        onChange?(new)
    }

    private func watch(_ session: CardDraftSession, as cardId: String) {
        session.onChange = { [weak self] in self?.onChange?(cardId) }
    }
}
