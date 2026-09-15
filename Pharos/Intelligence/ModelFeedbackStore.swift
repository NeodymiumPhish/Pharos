import Foundation
import CryptoKit

/// Where a thumbs up or thumbs down goes.
///
/// A rating is a hint about which FEATURE is answering badly, nothing more. The
/// prompt is never stored: `promptHash` is a short digest, so two ratings of
/// the same answer can be told apart from two ratings of different answers
/// without keeping what the model was shown — and a prompt can carry the user's
/// schema names and row values.
///
/// Recording is best-effort. A rating that cannot be written is logged and
/// dropped: the user pressed a thumb, and an alert about the local database
/// would be a worse answer than silence.
enum ModelFeedbackStore {

    /// The sink a rating is written to.
    ///
    /// Production leaves this alone — it calls the core. It is a `var` so a
    /// test can capture ratings without an initialised core behind the FFI.
    static var writer: (_ feature: String, _ promptHash: String, _ rating: Int) throws -> Void = {
        feature, promptHash, rating in
        try PharosCore.recordModelFeedback(feature: feature, promptHash: promptHash, rating: rating)
    }

    /// Record one rating. `rating` is `1` (helpful) or `-1` (not helpful).
    ///
    /// A nil `promptHash` is a feature that forgot to set one. The rating is
    /// still kept, under an empty hash: which feature was rated is the part
    /// worth having, and throwing the press away would hide the slip.
    static func record(feature: String, promptHash: String?, rating: Int) {
        let hash = promptHash ?? ""
        if hash.isEmpty {
            Log.intelligence.debug(
                "Feedback for \(feature, privacy: .public) has no prompt hash")
        }
        do {
            try writer(feature, hash, rating)
            Log.intelligence.info(
                "Recorded \(rating, privacy: .public) for \(feature, privacy: .public)")
        } catch {
            Log.intelligence.error(
                "Could not record feedback for \(feature, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A short, stable digest of a prompt: the first 16 hex characters of its
    /// SHA-256.
    ///
    /// Short on purpose. It has to group the ratings of one answer together,
    /// not to prove which prompt produced it, and a shorter value is one less
    /// thing that could be walked back to the user's data.
    static func promptHash(_ prompt: String) -> String {
        let digest = SHA256.hash(data: Data(prompt.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
