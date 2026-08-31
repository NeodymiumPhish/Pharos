use serde::{Deserialize, Serialize};

/// Full workspace record + payload used for upsert from Swift.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceUpsert {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub name_is_custom: bool,
    pub connection_id: String,
    pub connection_name: String,
    #[serde(default)]
    pub editor_text: String,
    /// JSON-encoded array of QueryVariable, stored verbatim.
    #[serde(default = "default_variables_json")]
    pub variables_json: String,
    #[serde(default)]
    pub cursor_position: Option<i64>,
}

fn default_variables_json() -> String { "[]".to_string() }

/// One executed result's association with the workspace it was produced in.
///
/// Recorded once, immediately after the run, by `associate_result`. Everything
/// here is captured at execution time and cannot be recovered later: `raw_sql`
/// is the editor segment as typed, `line_start`/`line_end` are where that
/// segment sat, and `custom_label` is a name the caller authored for the result
/// (a browse action names its own result). A later rename goes through
/// `update_result_meta` instead.
///
/// `line_start`/`line_end` are 1-based and inclusive. Both are None when the
/// result came from no editor segment — a browse action, a whole-editor run, a
/// drill — and the result tab then carries no `L1-3:` prefix in its name.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResultAssociation {
    pub history_id: String,
    pub workspace_id: String,
    pub result_order: i64,
    pub color_index: i64,
    #[serde(default)]
    pub raw_sql: Option<String>,
    #[serde(default)]
    pub line_start: Option<i64>,
    #[serde(default)]
    pub line_end: Option<i64>,
    #[serde(default)]
    pub custom_label: Option<String>,
}

/// Row shown in the workspace list (Layout B).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSummary {
    pub id: String,
    /// Already resolved via resolve_workspace_name.
    pub name: String,
    pub connection_name: String,
    pub distinct_db_count: i64,
    pub query_count: i64,
    pub last_activity_at: String,
    /// IDs of this workspace's queries whose SQL matched the active filter.
    /// Always empty when no filter is active. Same IDs as
    /// `WorkspaceResultMeta::id`, that is, `query_history.id`.
    pub matching_result_ids: Vec<String>,
}

/// One child result's metadata, for the preview pane and restore.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceResultMeta {
    pub id: String, // == query_history.id
    pub sql: String,
    pub result_order: Option<i64>,
    pub color_index: Option<i64>,
    pub custom_label: Option<String>,
    pub row_count: Option<i64>,
    pub column_count: Option<i64>,
    pub schema: Option<String>,
    pub table_names: Option<String>,
    pub has_results: bool,
    pub execution_time_ms: i64,
    pub executed_at: String,
    pub chart_view_state_json: Option<String>,
    pub raw_sql: Option<String>,
    /// The editor line range this result was produced from — 1-based and
    /// inclusive, None when it came from no editor segment. See
    /// `ResultAssociation`.
    pub line_start: Option<i64>,
    pub line_end: Option<i64>,
}

/// Full workspace payload returned on reopen.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceDetail {
    pub id: String,
    pub name: String,
    pub connection_id: String,
    pub connection_name: String,
    pub editor_text: String,
    pub variables_json: String,
    pub cursor_position: Option<i64>,
    pub results: Vec<WorkspaceResultMeta>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Swift side encodes its own property names with no key strategy, so
    /// the JSON on the wire is camelCase. A mismatch here is invisible until a
    /// field silently arrives as None — which is exactly how the result-tab line
    /// range went unstored.
    #[test]
    fn result_association_decodes_the_swift_payload() {
        let json = r#"{
            "historyId": "h1",
            "workspaceId": "ws1",
            "resultOrder": 2,
            "colorIndex": 3,
            "rawSql": "SELECT * FROM users WHERE id = {{id}}",
            "lineStart": 4,
            "lineEnd": 6,
            "customLabel": "users (browse)"
        }"#;
        let a: ResultAssociation = serde_json::from_str(json).expect("decode");
        assert_eq!(a.history_id, "h1");
        assert_eq!(a.workspace_id, "ws1");
        assert_eq!(a.result_order, 2);
        assert_eq!(a.color_index, 3);
        assert_eq!(a.raw_sql.as_deref(), Some("SELECT * FROM users WHERE id = {{id}}"));
        assert_eq!(a.line_start, Some(4));
        assert_eq!(a.line_end, Some(6));
        assert_eq!(a.custom_label.as_deref(), Some("users (browse)"));
    }

    /// Swift omits the optional keys it has nothing for. Every one of them must
    /// default rather than fail the whole decode.
    #[test]
    fn result_association_decodes_without_the_optional_keys() {
        let json = r#"{"historyId":"h1","workspaceId":"ws1","resultOrder":0,"colorIndex":0}"#;
        let a: ResultAssociation = serde_json::from_str(json).expect("decode");
        assert_eq!(a.raw_sql, None);
        assert_eq!(a.line_start, None);
        assert_eq!(a.line_end, None);
        assert_eq!(a.custom_label, None);
    }

    /// …and the reply Swift reads back carries the line range under the names
    /// `WorkspaceResultMeta` declares.
    #[test]
    fn result_meta_serializes_the_line_range_as_camel_case() {
        let meta = WorkspaceResultMeta {
            id: "h1".to_string(),
            sql: "SELECT 1".to_string(),
            result_order: Some(0),
            color_index: Some(0),
            custom_label: None,
            row_count: Some(1),
            column_count: Some(1),
            schema: None,
            table_names: None,
            has_results: true,
            execution_time_ms: 1,
            executed_at: "2026-08-31T00:00:00Z".to_string(),
            chart_view_state_json: None,
            raw_sql: None,
            line_start: Some(4),
            line_end: Some(6),
        };
        let json = serde_json::to_string(&meta).expect("encode");
        assert!(json.contains(r#""lineStart":4"#), "got {}", json);
        assert!(json.contains(r#""lineEnd":6"#), "got {}", json);
    }
}
