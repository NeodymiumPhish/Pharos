use serde::{Deserialize, Serialize};

/// One thumbs up or thumbs down on something the on-device model wrote.
///
/// `prompt_hash` is a short digest of the prompt, not the prompt. The prompt
/// can carry the user's schema names and row values; this record exists only to
/// say which FEATURE is answering badly, so it must never carry their data.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ModelFeedbackEntry {
    pub id: String,
    /// Which feature asked the model — "explain-error", "suggest-name", and so
    /// on. Free text, chosen by the feature, not an enum, so a new feature does
    /// not need a core change to be recorded.
    pub feature: String,
    pub prompt_hash: String,
    /// `1` for helpful, `-1` for not helpful. Stored as written: a value the
    /// core does not recognise is kept rather than dropped, so a later reader
    /// can see what happened.
    pub rating: i32,
    pub created_at: String,
}
