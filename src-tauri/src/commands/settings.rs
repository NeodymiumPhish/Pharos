use tauri::State;

use crate::db::sqlite;
use crate::models::AppSettings;
use crate::state::AppState;

#[tauri::command]
pub async fn load_settings(state: State<'_, AppState>) -> Result<AppSettings, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_settings(&db).map_err(|e| format!("Failed to load settings: {}", e))
}

#[tauri::command]
pub async fn save_settings(
    state: State<'_, AppState>,
    settings: AppSettings,
) -> Result<(), String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::save_settings(&db, &settings).map_err(|e| format!("Failed to save settings: {}", e))
}
