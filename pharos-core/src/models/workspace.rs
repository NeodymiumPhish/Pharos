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
