use crate::db::sqlite;
use crate::models::ModelFeedbackEntry;
use crate::state::AppState;

/// Record one thumbs up (`1`) or thumbs down (`-1`) on model output.
///
/// The prompt itself never reaches here — `prompt_hash` is a short digest the
/// caller computes, so two ratings of the same answer can be told apart from
/// two ratings of different answers without storing what was asked.
pub async fn record_model_feedback(
    state: &AppState,
    feature: String,
    prompt_hash: String,
    rating: i32,
) -> Result<(), String> {
    let id = uuid::Uuid::new_v4().to_string();
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::record_model_feedback(&db, &id, &feature, &prompt_hash, rating)
        .map_err(|e| format!("Failed to record model feedback: {}", e))
}

/// The most recent ratings, newest first.
pub async fn load_model_feedback(
    state: &AppState,
    limit: i32,
) -> Result<Vec<ModelFeedbackEntry>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_model_feedback(&db, limit)
        .map_err(|e| format!("Failed to load model feedback: {}", e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::executor::block_on;
    use rusqlite::Connection as SqliteConnection;

    /// An AppState over an in-memory database carrying the real schema — the
    /// same `create_schema` the app runs, so a missing `model_feedback` table
    /// fails here rather than at run time.
    fn state() -> AppState {
        let conn = SqliteConnection::open_in_memory().expect("sqlite");
        sqlite::create_schema(&conn).expect("schema");
        AppState::new(conn)
    }

    #[test]
    fn records_a_rating_and_reads_it_back() {
        let s = state();

        block_on(record_model_feedback(
            &s,
            "explain-error".to_string(),
            "a1b2c3d4e5f60718".to_string(),
            1,
        ))
        .expect("record");

        let loaded = block_on(load_model_feedback(&s, 10)).expect("load");
        assert_eq!(loaded.len(), 1);
        // Every field, not just the count: a column read from the wrong
        // position would still give a length of 1.
        assert_eq!(loaded[0].feature, "explain-error");
        assert_eq!(loaded[0].prompt_hash, "a1b2c3d4e5f60718");
        assert_eq!(loaded[0].rating, 1);
        assert!(!loaded[0].id.is_empty(), "the core assigns the id");
        assert!(!loaded[0].created_at.is_empty(), "the core stamps the time");
    }

    /// Changing one's mind about the SAME answer must leave two rows, not
    /// overwrite the first. An UPSERT on `prompt_hash` would lose the fact
    /// that the answer was rated twice, which is the signal worth having.
    #[test]
    fn a_second_rating_for_the_same_hash_is_a_second_row() {
        let s = state();
        let hash = "0f0f0f0f0f0f0f0f".to_string();

        block_on(record_model_feedback(&s, "draft-sql".into(), hash.clone(), -1)).expect("first");
        block_on(record_model_feedback(&s, "draft-sql".into(), hash.clone(), 1)).expect("second");

        let loaded = block_on(load_model_feedback(&s, 10)).expect("load");
        assert_eq!(loaded.len(), 2, "both presses are kept");
        assert!(loaded.iter().all(|e| e.prompt_hash == hash));
        // Both ratings survive, and they are different rows.
        let mut ratings: Vec<i32> = loaded.iter().map(|e| e.rating).collect();
        ratings.sort_unstable();
        assert_eq!(ratings, vec![-1, 1]);
        assert_ne!(loaded[0].id, loaded[1].id, "each press gets its own id");
    }

    /// `limit` is a ceiling, and the rows that survive it are the NEWEST. A
    /// fixture of three rows with three distinct features tells the two
    /// orderings apart: under an ascending order this returns "first".
    #[test]
    fn load_returns_the_newest_rows_within_the_limit() {
        let s = state();
        let conn = s.metadata_db.lock().unwrap();
        for (id, feature, stamp) in [
            ("f1", "first", "2026-01-01T00:00:00Z"),
            ("f2", "second", "2026-01-02T00:00:00Z"),
            ("f3", "third", "2026-01-03T00:00:00Z"),
        ] {
            conn.execute(
                "INSERT INTO model_feedback (id, feature, prompt_hash, rating, created_at) \
                 VALUES (?1, ?2, 'deadbeefdeadbeef', 1, ?3)",
                (id, feature, stamp),
            )
            .expect("insert");
        }
        drop(conn);

        let loaded = block_on(load_model_feedback(&s, 2)).expect("load");
        assert_eq!(loaded.len(), 2, "the limit is honoured");
        assert_eq!(loaded[0].feature, "third", "newest first");
        assert_eq!(loaded[1].feature, "second");
    }
}
