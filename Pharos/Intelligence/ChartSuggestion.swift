import AppKit
import FoundationModels

/// What the on-device model proposes for charting a result.
///
/// Three column fields carry one meaning per chart type (the category, the
/// measure, the optional third column); `ChartSuggestionPolicy.apply` reads
/// them back into roles and refuses anything the columns cannot support.
@Generable
struct ChartSuggestion {

    @Guide(description: "one of: bar, line, area, pie, scatter, heatmap, gantt")
    var chartType: String

    @Guide(description: "the X column: the category, the time column, scatter X, heatmap X, or the gantt label")
    var xColumn: String

    @Guide(description: "the measure column: the value, scatter Y, heatmap value, or the gantt start; nil for a count")
    var yColumn: String?

    @Guide(description: "an optional third column: the series for bar, line and area; heatmap Y; scatter size; the gantt end")
    var groupColumn: String?

    @Guide(description: "one of: sum, avg, count, min, max")
    var aggregation: String

    @Guide(description: "one of: auto, hour, day, week, month, year when X is a time column, else nil")
    var timeBucket: String?

    @Guide(description: "chart title, at most eight words")
    var title: String

    @Guide(description: "X axis title, at most four words")
    var xAxisTitle: String

    @Guide(description: "Y axis title, at most four words")
    var yAxisTitle: String

    @Guide(description: "one sentence saying why this chart fits the data")
    var reason: String
}

/// What a suggestion run hands back to the chart: a config to apply and the
/// words to show under the generated-content label.
struct ChartSuggestionOutcome {
    var config: ChartConfig
    var reason: String
    var promptHash: String
    /// False when the model's answer did not fit the columns and the top
    /// deterministic candidate was used instead.
    var fromModel: Bool
}

/// Asks the on-device model which chart fits a result.
///
/// One session per call: a chart for one result has nothing to learn from
/// another. The deterministic recommender has already run; its ranked
/// candidates go in the prompt so the model chooses with the shape in front
/// of it rather than from column names alone. Its answer is validated; an
/// answer that names a missing column or an impossible role falls back to the
/// first candidate, marked as such.
///
/// Everything this sends is schema and shape — names, types, counts, shares,
/// a span, and the SQL. No cell value reaches the prompt (see
/// `ColumnProfile`), so there is nothing for `RowDataConsent` to ask about.
@MainActor
final class ChartSuggester {

    /// The floor under a model that will not finish. No tools here, so a
    /// minute would be generous; half of one is the same answer sooner.
    static let timeout: Duration = .seconds(30)

    enum Failure: LocalizedError {
        case timedOut
        case nothingToChart
        var errorDescription: String? {
            switch self {
            case .timedOut: return String(localized: "The model did not finish in time. Try again.")
            case .nothingToChart: return String(localized: "There is nothing to chart in this result.")
            }
        }
    }

    func suggest(profiles: [ColumnProfile], rowCount: Int,
                 candidates: [ChartRecommendation], sql: String) async throws -> ChartSuggestionOutcome {
        try IntelligenceGuard.requireAvailable()
        guard !profiles.isEmpty else { throw Failure.nothingToChart }

        let prompt = ChartSuggestionPolicy.prompt(profiles: profiles, rowCount: rowCount,
                                                  candidates: candidates, sql: sql)
        let promptHash = ModelFeedbackStore.promptHash(prompt)
        let session = LanguageModelSession(
            instructions: IntelligenceInstructions.sqlSafety + "\n" + ChartSuggestionPolicy.instructions)

        // Race the request against the clock. Cancelling the request task
        // surfaces as a CancellationError from `value`, which is turned into
        // the timeout the user reads; a cancellation from OUTSIDE (the tab
        // changed) still cancels the inner task and is passed on as is.
        let request = Task { try await session.respond(to: prompt, generating: ChartSuggestion.self).content }
        let clock = Task { try await Task.sleep(for: Self.timeout); request.cancel() }
        defer { clock.cancel() }
        let answer: ChartSuggestion
        do {
            answer = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            Log.intelligence.error("suggest-chart: timed out")
            throw Failure.timedOut
        }

        let mirrored = ChartSuggestionPolicy.Answer(
            chartType: answer.chartType, xColumn: answer.xColumn, yColumn: answer.yColumn,
            groupColumn: answer.groupColumn, aggregation: answer.aggregation, timeBucket: answer.timeBucket,
            title: answer.title, xAxisTitle: answer.xAxisTitle, yAxisTitle: answer.yAxisTitle, reason: answer.reason)
        do {
            let config = try ChartSuggestionPolicy.apply(mirrored, profiles: profiles)
            return ChartSuggestionOutcome(config: config, reason: ChartSuggestionPolicy.reason(answer.reason),
                                          promptHash: promptHash, fromModel: true)
        } catch let rejection as ChartSuggestionPolicy.Rejection {
            // The KIND of rejection goes to the log, never the answer's text.
            Log.intelligence.error("suggest-chart: answer rejected (\(String(describing: rejection).prefix(40), privacy: .public))")
            guard let top = candidates.first else { throw Failure.nothingToChart }
            return ChartSuggestionOutcome(config: top.config, reason: top.reason, promptHash: promptHash, fromModel: false)
        }
    }

    /// One short sentence per failure the model can report.
    static func userMessage(for error: Error) -> String {
        if let failure = error as? Failure { return failure.localizedDescription }
        if let intelligence = error as? IntelligenceError { return intelligence.localizedDescription }
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return String(localized: "The model could not suggest a chart. Try again.")
        }
        switch generation {
        case .guardrailViolation:
            return String(localized: "The model would not answer for this result.")
        case .exceededContextWindowSize:
            return String(localized: "This result has too many columns for one request.")
        case .unsupportedLanguageOrLocale:
            return String(localized: "The model does not support this language yet.")
        case .assetsUnavailable:
            return String(localized: "The on-device model is not ready. Try again shortly.")
        default:
            return String(localized: "The model could not suggest a chart. Try again.")
        }
    }

    /// The failure KIND, for the log. Never the prompt, never the answer.
    static func kind(of error: Error) -> String {
        if let failure = error as? Failure { return String(describing: failure) }
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return String(describing: type(of: error))
        }
        return String(describing: generation).components(separatedBy: "(").first ?? "generation"
    }
}
