use crate::db::sqlite;
use crate::models::RecentFile;
use crate::state::AppState;

/// Every file in the Files navigator, newest first.
pub async fn load_recent_files(state: &AppState) -> Result<Vec<RecentFile>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::load_recent_files(&db).map_err(|e| format!("Failed to load recent files: {}", e))
}

/// Note that these files were opened. An entry keeps the newer of its stored
/// time and the given one, so a seed with an old time never moves a file down.
pub async fn touch_recent_files(state: &AppState, files: Vec<RecentFile>) -> Result<(), String> {
    let mut db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::touch_recent_files(&mut db, &files).map_err(|e| format!("Failed to note recent files: {}", e))
}

/// Remove these paths from the Files navigator. The files themselves, and any
/// connection record on them, are not touched.
pub async fn remove_recent_files(state: &AppState, paths: Vec<String>) -> Result<(), String> {
    let mut db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::remove_recent_files(&mut db, &paths).map_err(|e| format!("Failed to remove recent files: {}", e))
}
