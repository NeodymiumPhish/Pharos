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
}
