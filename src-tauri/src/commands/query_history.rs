use tauri::State;

use crate::db::sqlite;
use crate::models::QueryHistoryEntry;
use crate::state::AppState;

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
