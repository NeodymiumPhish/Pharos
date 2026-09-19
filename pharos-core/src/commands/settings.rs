
use crate::db::sqlite;
use crate::models::AppSettings;
use crate::state::AppState;

/// The settings as the core holds them: the cache filled at `pharos_init` and
/// refreshed by every `save_settings`. Nothing else writes the SQLite row, so
/// the cache is never stale.
pub async fn load_settings(state: &AppState) -> Result<AppSettings, String> {
    Ok((*state.settings()).clone())
}

/// Write the settings row, then refresh the cache so the next query, pool or
/// history write sees the new values.
pub async fn save_settings(
    state: &AppState,
    settings: AppSettings,
) -> Result<(), String> {
    {
        let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
        sqlite::save_settings(&db, &settings).map_err(|e| format!("Failed to save settings: {}", e))?;
    }
    state.replace_settings(settings);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn state() -> AppState {
        let conn = Connection::open_in_memory().unwrap();
        sqlite::create_schema(&conn).unwrap();
        AppState::new(conn)
    }

    /// Save writes the row AND the cache; load answers from the cache.
    #[test]
    fn save_refreshes_the_cache_and_the_row() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let state = state();
        let mut changed = AppSettings::default();
        changed.query.default_limit = 42;
        rt.block_on(save_settings(&state, changed.clone())).unwrap();

        assert_eq!(rt.block_on(load_settings(&state)).unwrap(), changed, "load answers from the cache");
        let db = state.metadata_db.lock().unwrap();
        assert_eq!(sqlite::load_settings(&db).unwrap(), changed, "the row was written too");
    }
}
