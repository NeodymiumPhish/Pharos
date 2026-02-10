use serde::Serialize;
use tauri::State;

use crate::db::sqlite;
use crate::models::QueryHistoryEntry;
use crate::state::AppState;

/// Cached query result data returned when loading a specific history entry's results
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryHistoryResultData {
    pub columns: serde_json::Value,
    pub rows: serde_json::Value,
}

/// Load query history entries with optional filtering
#[tauri::command]
pub async fn load_query_history(
    connection_id: Option<String>,
    search: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
    state: State<'_, AppState>,
) -> Result<Vec<QueryHistoryEntry>, String> {
    let db = state.metadata_db.lock().unwrap();
    let entries = sqlite::load_query_history(
        &db,
        connection_id.as_deref(),
        search.as_deref(),
        limit.unwrap_or(100),
        offset.unwrap_or(0),
    )
    .map_err(|e| format!("Failed to load query history: {}", e))?;

    Ok(entries)
}

/// Delete a single query history entry
#[tauri::command]
pub async fn delete_query_history_entry(
    entry_id: String,
    state: State<'_, AppState>,
) -> Result<bool, String> {
    let db = state.metadata_db.lock().unwrap();
    sqlite::delete_query_history_entry(&db, &entry_id)
        .map_err(|e| format!("Failed to delete history entry: {}", e))
}

/// Clear all query history
#[tauri::command]
pub async fn clear_query_history(
    state: State<'_, AppState>,
) -> Result<(), String> {
    let db = state.metadata_db.lock().unwrap();
    sqlite::clear_query_history(&db)
        .map_err(|e| format!("Failed to clear query history: {}", e))
}

/// Update cached results for a history entry (after loading more rows)
#[tauri::command]
pub async fn update_query_history_results(
    entry_id: String,
    row_count: i64,
    result_columns: String,
    result_rows: String,
    state: State<'_, AppState>,
) -> Result<bool, String> {
    // Enforce same 5MB size limit as initial save
    if result_columns.len() + result_rows.len() >= 5_000_000 {
        return Ok(false);
    }
    let db = state.metadata_db.lock().unwrap();
    sqlite::update_query_history_results(&db, &entry_id, row_count, &result_columns, &result_rows)
        .map_err(|e| format!("Failed to update history results: {}", e))
}

/// Load cached result data for a specific history entry
#[tauri::command]
pub async fn get_query_history_result(
    entry_id: String,
    state: State<'_, AppState>,
) -> Result<Option<QueryHistoryResultData>, String> {
    let db = state.metadata_db.lock().unwrap();
    let result = sqlite::get_query_history_result(&db, &entry_id)
        .map_err(|e| format!("Failed to load history result: {}", e))?;

    match result {
        Some((columns_json, rows_json)) => {
            let columns: serde_json::Value = serde_json::from_str(&columns_json)
                .map_err(|e| format!("Failed to parse cached columns: {}", e))?;
            let rows: serde_json::Value = serde_json::from_str(&rows_json)
                .map_err(|e| format!("Failed to parse cached rows: {}", e))?;
            Ok(Some(QueryHistoryResultData { columns, rows }))
        }
        None => Ok(None),
    }
}
