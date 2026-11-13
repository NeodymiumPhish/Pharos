import Foundation

/// What a card's "Describe the query" draft asks the model with: the
/// `SQLDraftPipeline`, its answer reviewed by `SQLDraftPolicy` and put into
/// the words the card's strip shows.
@MainActor
enum CardDraftWorker {

    /// An answer that is not offered: a refused write, or no statement.
    struct Declined: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Where a draft is written: the tab's connection and schema when the
    /// draft's turn comes.
    struct Context {
        let catalog: () async -> DraftCatalog
        let defaultSchema: String?
        let dialect: String
        /// Reads the tables' DDL from the tab's database; nil drafts from
        /// names, types and keys alone.
        var definitions: SQLDraftPipeline.DefinitionSource?
    }

    /// A worker that asks `context()` for the tab's database each time a
    /// draft starts, so a retry after a schema change reads the new schema.
    /// nil from `context` means the tab has no connected database.
    static func make(context: @escaping @MainActor () -> Context?) -> CardDraftSession.Worker {
        { request, statement, progress in
            guard let context = context() else {
                throw Declined(message: String(localized: "Connect this tab to a database to draft a query."))
            }
            let pipeline = SQLDraftPipeline(catalog: await context.catalog(), defaultSchema: context.defaultSchema,
                                            dialect: context.dialect, definitions: context.definitions)
            try Task.checkCancellation()
            pipeline.onStage = { stage in progress(progressText(stage, adjusting: statement != nil)) }
            let result = try await pipeline.draft(request, adjusting: statement)
            var draft = try draft(from: result, request: request)
            draft.isAdjustment = statement != nil
            return draft
        }
    }

    static func progressText(_ stage: SQLDraftPipeline.Stage, adjusting: Bool = false) -> String {
        if adjusting, stage == .writing { return String(localized: "Changing the query\u{2026}") }
        switch stage {
        case .finding: return String(localized: "Finding tables\u{2026}")
        case .choosing: return String(localized: "Choosing tables\u{2026}")
        case .reading: return String(localized: "Reading the tables\u{2026}")
        case .writing: return String(localized: "Writing the query\u{2026}")
        case .checking: return String(localized: "Checking names\u{2026}")
        case .repairing: return String(localized: "Fixing names\u{2026}")
        }
    }

    /// Review the pipeline's answer and say what it reads.
    static func draft(from result: SQLDraftPipeline.Result, request: String) throws -> CardDraftSession.Draft {
        let reviewed = SQLDraftPolicy.review(
            result.sql,
            allowWriteStatements: ModelAvailability.shared.isAvailable(for: .draftWriteStatements))

        // The user has said Pharos must draft reads only. The statement is
        // not put on screen at all — showing it and refusing to insert it
        // would be the same disclosure with extra steps.
        guard !reviewed.isRefused else { throw Declined(message: reviewed.warning ?? "") }
        // An answer with no statement in it is a failure with a nicer shape:
        // offer the retry, not an Insert that inserts nothing.
        guard !reviewed.isEmpty else {
            throw Declined(message: String(localized: "The model did not write a statement. Try again."))
        }

        // What the statement reads, worked out by Pharos rather than told by
        // the model (see `SQLDraft`).
        var note = result.reads.isEmpty
            ? String(localized: "Reads no table Pharos knows.")
            : String(localized: "Reads \(ListFormatter.localizedString(byJoining: result.reads.map(\.description))).")
        // Names the check could not match are said, not hidden: the draft
        // may still be the right shape, and the analyst can fix a name.
        if let first = result.problems.first {
            let more = result.problems.count - 1
            let problem = more > 0
                ? String(localized: "Check before running: \(first) (\(more) more)")
                : String(localized: "Check before running: \(first)")
            note = problem + "\n" + note
        }
        // Pharos's own corrections are said too: the statement is no longer
        // exactly what the model wrote.
        if !result.fixes.isEmpty {
            note += "\n" + String(localized: "Pharos corrected: \(result.fixes.joined(separator: " "))")
        }
        if let warning = reviewed.warning { note = "\(warning)\n\(note)" }

        return CardDraftSession.Draft(
            sql: reviewed.sql, note: note,
            noteIsCaution: reviewed.warning != nil || !result.problems.isEmpty,
            warning: reviewed.warning,
            promptHash: ModelFeedbackStore.promptHash(request))
    }

    static var timeoutMessage: String {
        String(localized: "The model did not finish in time. Try again, or allow more time in Settings \u{25B8} Intelligence.")
    }

    /// One short sentence per failure the model can report.
    static func message(for error: Error) -> String {
        if let declined = error as? Declined { return declined.message }
        if let intelligence = error as? IntelligenceError {
            return intelligence.localizedDescription
        }
        // A custom endpoint's failures say what to do about them.
        if let endpoint = error as? IntelligenceEndpointError { return endpoint.localizedDescription }
        if let failure = error as? SQLDraftPipeline.Failure {
            return failure.localizedDescription
        }
        // `ModelErrorKind`, not `GenerationError`: macOS 27 throws
        // `LanguageModelError`, and a switch on the old type alone showed
        // the generic sentence for every failure there.
        switch ModelErrorKind.of(error) {
        case .guardrailViolation, .refusal:
            return String(localized: "The model would not answer that. Try describing the query another way.")
        case .contextSizeExceeded:
            return String(localized: "That was too much for one request. Choose a schema first, or describe a smaller query.")
        case .unsupportedLanguageOrLocale:
            return String(localized: "The model does not support this language yet.")
        case .rateLimited, .concurrentRequests:
            return String(localized: "The model is busy. Try again in a moment.")
        case .assetsUnavailable:
            return String(localized: "The model is not ready yet. Try again when Apple Intelligence has finished downloading.")
        default:
            return String(localized: "The model could not draft a query. Try again.")
        }
    }
}
