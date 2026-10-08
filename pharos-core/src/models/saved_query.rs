use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedQuery {
    pub id: String,
    pub name: String,
    pub folder: Option<String>,
    pub sql: String,
    pub connection_id: Option<String>,
    pub variables: Option<String>,
    /// The query's cards as JSON (Swift's `CardPersistence`): a saved query is
    /// a whole tab of cards. `sql` holds the latest version of each as text.
    #[serde(default)]
    pub cards_json: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    /// The schema the Session's tab was on when it was saved.
    #[serde(default)]
    pub schema_name: Option<String>,
    /// The snapshot of results that belongs to this Session, or None when it
    /// was never saved with results (every saved query from before Sessions).
    #[serde(default)]
    pub results_snapshot_id: Option<String>,
    #[serde(default)]
    pub results_saved_at: Option<String>,
    /// Compressed bytes of the stored results.
    #[serde(default)]
    pub results_bytes: Option<i64>,
    /// Results in the snapshot, with or without their rows.
    #[serde(default)]
    pub result_count: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateSavedQuery {
    pub name: String,
    pub folder: Option<String>,
    pub sql: String,
    pub connection_id: Option<String>,
    pub variables: Option<String>,
    #[serde(default)]
    pub cards_json: Option<String>,
    #[serde(default)]
    pub schema_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSavedQuery {
    pub id: String,
    pub name: Option<String>,
    pub folder: Option<String>,
    pub sql: Option<String>,
    pub variables: Option<String>,
    /// None leaves the stored cards alone.
    #[serde(default)]
    pub cards_json: Option<String>,
}

// ==================== Session results ====================
//
// A saved query is a saved Session: its cards AND the result each card holds.
// The results are written in two phases so a failed save never damages the
// snapshot already stored: each result is staged under a new snapshot id, then
// one commit makes that snapshot the Session's own and drops the old one.

/// One result to stage. `columns`, `rows` and `row_identity` are the JSON the
/// grid holds, passed through to the compressor without being parsed.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StageSavedQueryResult {
    pub saved_query_id: String,
    pub snapshot_id: String,
    /// The run of the card the result came from (`CardRunRecord.runId`).
    pub run_id: String,
    pub card_id: String,
    /// 0 is kept first when the Session is over its budget.
    pub priority: i64,
    /// "rows" or "affected".
    pub kind: String,
    pub sql: String,
    #[serde(default)]
    pub raw_sql: Option<String>,
    #[serde(default)]
    pub schema_name: Option<String>,
    pub executed_at: String,
    pub execution_time_ms: i64,
    #[serde(default)]
    pub rows_affected: Option<i64>,
    #[serde(default)]
    pub row_count: Option<i64>,
    #[serde(default)]
    pub has_more: bool,
    #[serde(default)]
    pub chart_view_state_json: Option<String>,
    #[serde(default)]
    pub columns: Option<Box<serde_json::value::RawValue>>,
    #[serde(default)]
    pub rows: Option<Box<serde_json::value::RawValue>>,
    #[serde(default)]
    pub row_identity: Option<Box<serde_json::value::RawValue>>,
}

/// What staging one result did.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StagedSavedQueryResult {
    pub id: String,
    /// False when the rows did not fit in the budget: only the metadata is kept.
    pub stored: bool,
    pub compressed_bytes: i64,
}

/// A result stored by an earlier save that is not in memory now (the result
/// limit let it go) and stays in the Session.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeepSavedQueryResult {
    pub run_id: String,
    pub priority: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitSavedQuerySnapshot {
    pub saved_query_id: String,
    pub snapshot_id: String,
    pub sql: String,
    /// None when the cards did not encode: the Session then splits `sql`.
    #[serde(default)]
    pub cards_json: Option<String>,
    #[serde(default)]
    pub connection_id: Option<String>,
    #[serde(default)]
    pub schema_name: Option<String>,
    #[serde(default)]
    pub keep: Vec<KeepSavedQueryResult>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommittedSavedQuerySnapshot {
    pub saved_query: SavedQuery,
    /// Runs whose rows were dropped to keep the Session under its budget.
    pub dropped_run_ids: Vec<String>,
}

/// One stored result of a Session, without its rows.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SavedQueryResultMeta {
    pub id: String,
    pub run_id: String,
    pub card_id: String,
    pub kind: String,
    pub sql: String,
    pub raw_sql: Option<String>,
    pub schema_name: Option<String>,
    pub executed_at: String,
    pub execution_time_ms: i64,
    pub rows_affected: Option<i64>,
    pub row_count: Option<i64>,
    pub has_more: bool,
    pub chart_view_state_json: Option<String>,
    /// The rows are stored. False when the budget dropped them.
    pub has_rows: bool,
    pub compressed_bytes: i64,
}
