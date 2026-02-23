
use crate::db::sqlite;
use crate::models::AppSettings;
use crate::state::AppState;

pub async fn load_settings(state: &AppState) -> Result<AppSettings, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_settings(&db).map_err(|e| format!("Failed to load settings: {}", e))
}

pub async fn save_settings(
    state: &AppState,
    settings: AppSettings,
) -> Result<(), String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::save_settings(&db, &settings).map_err(|e| format!("Failed to save settings: {}", e))
}
