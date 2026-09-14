use crate::db::sqlite;
use crate::models::Session;
use crate::state::AppState;

pub async fn load_session(state: &AppState) -> Result<Session, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_session(&db).map_err(|e| format!("Failed to load session: {}", e))
}

pub async fn save_session(state: &AppState, session: Session) -> Result<(), String> {
    let mut db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::save_session(&mut db, &session).map_err(|e| format!("Failed to save session: {}", e))
}
