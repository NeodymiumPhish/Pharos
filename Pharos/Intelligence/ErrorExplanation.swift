import Foundation
import FoundationModels

/// What the model says about one failed statement.
///
/// Three fields, because that is the shape of a useful answer to "why did this
/// fail": what went wrong, where, and what to do about it. Structured rather
/// than free text so the sheet can lay it out — and so a half-finished
/// generation still shows the first sentence while the rest arrives.
@Generable
struct ErrorExplanation {

    @Guide(description: "one sentence naming the cause")
    var cause: String

    @Guide(description: "where in the statement, if known")
    var location: String?

    @Guide(description: "one to three concrete fixes", .count(1...3))
    var fixes: [String]
}

/// One "Explain this error" run, as the view needs it.
struct ErrorExplanationRun {

    /// The digest of the prompt behind this run, for `GeneratedContentLabel`.
    /// The prompt itself is never kept.
    let promptHash: String

    /// The answer as it fills in. Each element is the whole struct so far, with
    /// the fields that have not arrived still nil.
    let updates: AsyncThrowingStream<ErrorExplanation.PartiallyGenerated, Error>
}

/// Opens a session with the on-device model and streams an explanation back.
///
/// One session per run, never reused: two unrelated failures share no context,
/// and a session that carried the previous error's transcript would be both
/// slower and wrong. `explain` therefore replaces `session` every time, which
/// also ends the previous run.
@MainActor
final class ErrorExplainer: ObservableObject {

    /// True from the moment a run starts until it finishes or fails. The view
    /// shows its progress row while it holds.
    @Published private(set) var isExplaining = false

    /// Kept only so a new run — or `cancel()` — releases the old one.
    private var session: LanguageModelSession?
    private var task: Task<Void, Never>?

    private static let instructions = IntelligenceInstructions.sqlSafety + " "
        + """
        Explain PostgreSQL errors to an analyst in plain language. Name the \
        cause, the location if the message gives one, and one to three fixes. \
        Never propose destructive commands.
        """

    /// Start explaining `failure`. Throws when the model may not be used at all,
    /// so the caller can say so without opening a session.
    ///
    /// The returned stream ends when the answer is complete. Dropping it — or
    /// calling `explain` again — cancels the generation.
    func explain(
        failure: QueryFailure,
        knownObjects: ErrorExplanationPrompt.KnownObjects
    ) throws -> ErrorExplanationRun {
        try IntelligenceGuard.requireAvailable()
        cancel()

        let prompt = ErrorExplanationPrompt.build(
            message: failure.message, sql: failure.sql, knownObjects: knownObjects)
        // The prompt carries the user's SQL and schema names, so only its digest
        // is ever logged or stored.
        let hash = ModelFeedbackStore.promptHash(prompt)

        let session = LanguageModelSession(instructions: Self.instructions)
        self.session = session
        isExplaining = true
        Log.intelligence.info("explain-error: started \(hash, privacy: .public)")

        let updates = AsyncThrowingStream<ErrorExplanation.PartiallyGenerated, Error> { continuation in
            let task = Task { @MainActor in
                do {
                    let stream = session.streamResponse(
                        to: prompt, generating: ErrorExplanation.self)
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)
                    }
                    self.isExplaining = false
                    Log.intelligence.info("explain-error: finished \(hash, privacy: .public)")
                    continuation.finish()
                } catch is CancellationError {
                    self.isExplaining = false
                    continuation.finish()
                } catch {
                    self.isExplaining = false
                    Log.intelligence.error(
                        "explain-error: failed \(hash, privacy: .public): \(Self.kind(of: error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            self.task = task
            continuation.onTermination = { _ in task.cancel() }
        }
        return ErrorExplanationRun(promptHash: hash, updates: updates)
    }

    /// Stop the run in flight, if any. Safe to call when none is.
    func cancel() {
        task?.cancel()
        task = nil
        session = nil
        isExplaining = false
    }

    // MARK: - Errors

    /// One short line for the user, under the Retry button.
    ///
    /// Every `GenerationError` gets a sentence saying what to do, because the
    /// framework's own `localizedDescription` is written for a developer.
    static func userMessage(for error: Error) -> String {
        if let error = error as? IntelligenceError {
            return error.localizedDescription
        }
        guard let error = error as? LanguageModelSession.GenerationError else {
            return String(localized: "The explanation could not be generated.")
        }
        switch error {
        case .exceededContextWindowSize:
            return String(localized: "The statement is too long to explain.")
        case .guardrailViolation:
            return String(localized: "The model declined to explain this error.")
        case .unsupportedLanguageOrLocale:
            return String(localized: "The model does not support this language.")
        case .assetsUnavailable:
            return String(localized: "The on-device model is not ready. Try again shortly.")
        case .decodingFailure, .unsupportedGuide, .rateLimited, .refusal, .concurrentRequests:
            return String(localized: "The explanation could not be generated.")
        @unknown default:
            return String(localized: "The explanation could not be generated.")
        }
    }

    /// The failure KIND, for the log. Never the prompt, never the answer.
    static func kind(of error: Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else {
            return String(describing: type(of: error))
        }
        switch error {
        case .exceededContextWindowSize: return "exceededContextWindowSize"
        case .assetsUnavailable: return "assetsUnavailable"
        case .guardrailViolation: return "guardrailViolation"
        case .unsupportedGuide: return "unsupportedGuide"
        case .unsupportedLanguageOrLocale: return "unsupportedLanguageOrLocale"
        case .decodingFailure: return "decodingFailure"
        case .rateLimited: return "rateLimited"
        case .refusal: return "refusal"
        case .concurrentRequests: return "concurrentRequests"
        @unknown default: return "unknown"
        }
    }
}
