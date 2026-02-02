use tauri::State;

use crate::db::sqlite;
use crate::models::{CreateSavedQuery, SavedQuery, UpdateSavedQuery};
use crate::state::AppState;

#[tauri::command]
pub async fn create_saved_query(
    state: State<'_, AppState>,
    query: CreateSavedQuery,
) -> Result<SavedQuery, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::create_saved_query(&db, &id, &query).map_err(|e| format!("Failed to create saved query: {}", e))
}

#[tauri::command]
pub async fn load_saved_queries(state: State<'_, AppState>) -> Result<Vec<SavedQuery>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_saved_queries(&db).map_err(|e| format!("Failed to load saved queries: {}", e))
}

#[tauri::command]
pub async fn get_saved_query(
    state: State<'_, AppState>,
    query_id: String,
) -> Result<Option<SavedQuery>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::get_saved_query(&db, &query_id).map_err(|e| format!("Failed to get saved query: {}", e))
}

#[tauri::command]
pub async fn update_saved_query(
    state: State<'_, AppState>,
    update: UpdateSavedQuery,
) -> Result<Option<SavedQuery>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::update_saved_query(&db, &update).map_err(|e| format!("Failed to update saved query: {}", e))
}

#[tauri::command]
pub async fn delete_saved_query(
    state: State<'_, AppState>,
    query_id: String,
) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::delete_saved_query(&db, &query_id).map_err(|e| format!("Failed to delete saved query: {}", e))
}
