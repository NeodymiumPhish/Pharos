use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryHistoryEntry {
    pub id: String,
    pub connection_id: String,
    pub connection_name: String,
    pub sql: String,
    pub row_count: Option<i64>,
    pub execution_time_ms: i64,
    pub executed_at: String, // ISO 8601
    pub has_results: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schema: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub table_names: Option<String>,
    /// Tags the origin of a run (e.g. "chart-aggregation" for a push-down
    /// server-aggregation query). `None` for normal, untagged runs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    /// How the run ENDED: `ok`, `error` or `cancelled`. See the constants
    /// below — the column is plain TEXT, so this is the one place the three
    /// spellings are written down.
    ///
    /// `serde(default)` and the column's `DEFAULT 'ok'` say the same thing
    /// from two directions: every row recorded before this column existed was
    /// a successful one, because a failure was not recorded at all.
    #[serde(default = "default_history_status")]
    pub status: String,
    /// What the server (or the client) said, for a row whose `status` is not
    /// `ok`. `None` on a successful row.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

/// A run that produced a result. Everything recorded before the `status`
/// column existed is this, because only successes were recorded.
pub const HISTORY_STATUS_OK: &str = "ok";
/// A run the server (or the client) refused or failed.
pub const HISTORY_STATUS_ERROR: &str = "error";
/// A run the user stopped.
pub const HISTORY_STATUS_CANCELLED: &str = "cancelled";

fn default_history_status() -> String { HISTORY_STATUS_OK.to_string() }

impl QueryHistoryEntry {
    /// True when this row has a result behind it — the only rows a workspace
    /// rebuild can restore, and the only rows "Succeeded" lists.
    pub fn is_ok_status(&self) -> bool {
        self.status == HISTORY_STATUS_OK
    }
}

/// Which rows a history load asks for.
///
/// `Succeeded` is `status = 'ok'` and `Failed` is everything else, so a row
/// carrying a status this build has never heard of is still reachable — it
/// counts as a failure rather than disappearing from both lists.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HistoryStatusScope {
    #[default]
    All,
    Succeeded,
    Failed,
}

impl HistoryStatusScope {
    /// The SQL fragment this scope adds to a `query_history` query, or None
    /// for `All`, which adds nothing.
    ///
    /// Written as a literal rather than a bound parameter because the only
    /// value in it is `HISTORY_STATUS_OK`, a constant of this crate: there is
    /// no caller input anywhere in the string.
    pub fn sql_predicate(self) -> Option<&'static str> {
        match self {
            HistoryStatusScope::All => None,
            HistoryStatusScope::Succeeded => Some(" AND status = 'ok'"),
            HistoryStatusScope::Failed => Some(" AND status <> 'ok'"),
        }
    }
}

/// Everything about a failed run that only the Swift session knows.
///
/// The core learns a query failed inside `commands::query`, but not which
/// workspace the editor tab belongs to nor which editor lines the statement
/// came from — both live in the Swift session — so the RECORD is driven from
/// Swift, through `record_failed_query`, rather than from the failure site.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FailedQueryRecord {
    pub connection_id: String,
    /// The substituted SQL that actually ran.
    pub sql: String,
    /// The pre-substitution `{{var}}` form, when the run had one.
    #[serde(default)]
    pub raw_sql: Option<String>,
    /// What the server (or the client) said.
    pub message: String,
    /// `error` or `cancelled`. Anything else is stored as given: this is the
    /// caller's word about its own run, and a status the load cannot name
    /// still reads as a failure.
    #[serde(default = "default_failed_status")]
    pub status: String,
    #[serde(default)]
    pub schema: Option<String>,
    #[serde(default)]
    pub table_names: Option<String>,
    /// The editor tab's workspace, when it has one.
    #[serde(default)]
    pub workspace_id: Option<String>,
    /// 1-based, inclusive; both None when the run came from no editor segment.
    #[serde(default)]
    pub line_start: Option<i64>,
    #[serde(default)]
    pub line_end: Option<i64>,
    /// How long the run took before it failed.
    #[serde(default)]
    pub execution_time_ms: i64,
}

fn default_failed_status() -> String { HISTORY_STATUS_ERROR.to_string() }

#[cfg(test)]
mod tests {
    use super::*;

    /// `QueryHistoryEntry` carries `rename_all = "camelCase"`, so the two new
    /// fields go over the FFI as `status` and `errorMessage`. Swift's
    /// `QueryHistoryEntry` decodes those exact keys; a snake_case spelling
    /// would read as absent and every row would claim to have succeeded.
    #[test]
    fn entry_sends_status_and_error_message_as_camel_case() {
        let entry = QueryHistoryEntry {
            id: "h1".into(),
            connection_id: "c1".into(),
            connection_name: "prod-db".into(),
            sql: "SELCT 1".into(),
            row_count: None,
            execution_time_ms: 3,
            executed_at: "2026-09-19T00:00:00Z".into(),
            has_results: false,
            schema: None,
            column_count: None,
            table_names: None,
            source: None,
            status: HISTORY_STATUS_ERROR.to_string(),
            error_message: Some("syntax error".into()),
        };
        let json = serde_json::to_string(&entry).expect("encode");
        assert!(json.contains(r#""status":"error""#), "got {}", json);
        assert!(json.contains(r#""errorMessage":"syntax error""#), "got {}", json);
        assert!(!json.contains("error_message"), "got {}", json);
    }

    /// A blob written before the column existed still decodes, and reads as a
    /// success — the same promise the column's `DEFAULT 'ok'` makes in SQLite.
    #[test]
    fn an_entry_without_a_status_decodes_as_ok() {
        let json = r#"{"id":"h1","connectionId":"c1","connectionName":"p","sql":"SELECT 1",
                       "rowCount":1,"executionTimeMs":2,"executedAt":"2026-09-19T00:00:00Z",
                       "hasResults":true}"#;
        let entry: QueryHistoryEntry = serde_json::from_str(json).expect("decode");
        assert_eq!(entry.status, HISTORY_STATUS_OK);
        assert!(entry.is_ok_status());
        assert_eq!(entry.error_message, None);
    }

    /// The scope the Swift side sends is a camelCase string, and the fragment
    /// each one contributes is the one the load appends.
    #[test]
    fn status_scope_decodes_from_swift_and_maps_to_its_predicate() {
        let all: HistoryStatusScope = serde_json::from_str("\"all\"").expect("all");
        let ok: HistoryStatusScope = serde_json::from_str("\"succeeded\"").expect("succeeded");
        let bad: HistoryStatusScope = serde_json::from_str("\"failed\"").expect("failed");
        assert_eq!(all, HistoryStatusScope::All);
        assert_eq!(all, HistoryStatusScope::default());
        assert_eq!(all.sql_predicate(), None);
        assert_eq!(ok.sql_predicate(), Some(" AND status = 'ok'"));
        assert_eq!(bad.sql_predicate(), Some(" AND status <> 'ok'"));
    }

    /// The record Swift sends: only the four fields a failure always has are
    /// required, and the status defaults to `error` rather than to `ok` — a
    /// record with no status is still a failure.
    #[test]
    fn failed_record_decodes_from_its_minimum() {
        let json = r#"{"connectionId":"c1","sql":"SELCT 1","message":"syntax error"}"#;
        let record: FailedQueryRecord = serde_json::from_str(json).expect("decode");
        assert_eq!(record.connection_id, "c1");
        assert_eq!(record.status, HISTORY_STATUS_ERROR);
        assert_eq!(record.workspace_id, None);
        assert_eq!(record.line_start, None);
        assert_eq!(record.execution_time_ms, 0);
    }

    /// …and the full form, with the two things only the Swift session knows.
    #[test]
    fn failed_record_reads_the_workspace_and_the_line_range() {
        let json = r#"{"connectionId":"c1","sql":"SELCT 1","rawSql":"SELCT {{n}}",
                       "message":"cancelled","status":"cancelled","schema":"public",
                       "tableNames":"users","workspaceId":"ws1","lineStart":4,"lineEnd":6,
                       "executionTimeMs":120}"#;
        let record: FailedQueryRecord = serde_json::from_str(json).expect("decode");
        assert_eq!(record.status, HISTORY_STATUS_CANCELLED);
        assert_eq!(record.workspace_id.as_deref(), Some("ws1"));
        assert_eq!(record.raw_sql.as_deref(), Some("SELCT {{n}}"));
        assert_eq!(record.line_start, Some(4));
        assert_eq!(record.line_end, Some(6));
        assert_eq!(record.table_names.as_deref(), Some("users"));
        assert_eq!(record.execution_time_ms, 120);
    }
}
