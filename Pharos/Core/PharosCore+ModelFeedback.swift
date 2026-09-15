import Foundation
import CPharosCore

// MARK: - Model Feedback

extension PharosCore {

    /// Record one rating of something the on-device model wrote.
    ///
    /// `rating` is `1` (helpful) or `-1` (not helpful). `promptHash` is a short
    /// digest — see `ModelFeedbackStore.promptHash(_:)` — never the prompt
    /// itself.
    ///
    /// Both arguments cross as plain C-strings, so neither `callSync` (nothing
    /// in / JSON in) fits; this is the third shape, checked through
    /// `scalarResult` so the core's `{"error": ...}` throws rather than being
    /// read as a result.
    static func recordModelFeedback(feature: String, promptHash: String, rating: Int) throws {
        _ = try scalarResult {
            feature.withCString { f in
                promptHash.withCString { h in
                    pharos_record_model_feedback(f, h, Int32(clamping: rating))
                }
            }
        }
    }

    /// The most recent ratings, newest first.
    static func loadModelFeedback(limit: Int) throws -> [ModelFeedbackEntry] {
        try callSync { pharos_load_model_feedback(Int32(clamping: limit)) }
    }
}
