import Foundation

/// One thumbs up or thumbs down the user gave to something the on-device model
/// wrote.
///
/// `promptHash` is a short digest of the prompt, never the prompt: a prompt can
/// carry the user's schema names and row values, and this record exists only to
/// say which feature is answering badly.
struct ModelFeedbackEntry: Codable, Identifiable, Equatable {
    let id: String
    /// Which feature asked the model — `"explain-error"`, `"suggest-name"` and
    /// so on. Free text chosen by the feature.
    let feature: String
    let promptHash: String
    /// `1` for helpful, `-1` for not helpful.
    let rating: Int
    let createdAt: String
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly
}
