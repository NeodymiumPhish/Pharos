use crate::db::sqlite;
use crate::models::{AddTagRules, CreateTag, Tag, UpdateTag};
use crate::state::AppState;

/// Every tag, globally. Tags carry no connection id by design.
pub async fn load_tags(state: &AppState) -> Result<Vec<Tag>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_tags(&db).map_err(|e| format!("Failed to load tags: {}", e))
}

/// The id is minted here, matching `create_saved_query`.
pub async fn create_tag(state: &AppState, create: CreateTag) -> Result<Tag, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::create_tag(&db, &id, &create).map_err(|e| format!("Failed to create tag: {}", e))
}

/// Returns how many tuples were actually inserted; a repeat is absorbed, not an
/// error.
pub async fn add_tag_tuples(state: &AppState, payload: AddTagRules) -> Result<usize, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::add_tag_tuples(&db, &payload).map_err(|e| format!("Failed to add tag values: {}", e))
}

pub async fn update_tag(state: &AppState, update: UpdateTag) -> Result<Option<Tag>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::update_tag(&db, &update).map_err(|e| format!("Failed to update tag: {}", e))
}

/// Returns false for an unknown id, exactly as `delete_saved_query` does.
pub async fn delete_tag(state: &AppState, tag_id: String) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::delete_tag(&db, &tag_id).map_err(|e| format!("Failed to delete tag: {}", e))
}

pub async fn delete_tag_tuples(state: &AppState, tuple_ids: Vec<String>) -> Result<usize, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::delete_tag_tuples(&db, &tuple_ids)
        .map_err(|e| format!("Failed to remove tag values: {}", e))
}
