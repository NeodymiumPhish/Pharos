use crate::db::sqlite;
use crate::models::{CreateTagLabel, RowTag, TagLabel, UpdateTagLabel, UpsertRowTag};
use crate::state::AppState;

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

pub async fn load_tag_labels(state: &AppState) -> Result<Vec<TagLabel>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_tag_labels(&db).map_err(|e| format!("Failed to load tag labels: {}", e))
}

/// The id is minted here, not in the CRUD, matching `create_saved_query`.
pub async fn create_tag_label(
    state: &AppState,
    label: CreateTagLabel,
) -> Result<TagLabel, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::create_tag_label(&db, &id, &label)
        .map_err(|e| format!("Failed to create tag label: {}", e))
}

pub async fn update_tag_label(
    state: &AppState,
    update: UpdateTagLabel,
) -> Result<Option<TagLabel>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::update_tag_label(&db, &update)
        .map_err(|e| format!("Failed to update tag label: {}", e))
}

/// Returns 0 for an unknown label. That is not an error: the caller asks this
/// only to phrase a delete confirmation.
pub async fn count_tags_for_label(state: &AppState, label_id: String) -> Result<i64, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::count_tags_for_label(&db, &label_id)
        .map_err(|e| format!("Failed to count tags for label: {}", e))
}

/// Returns false for an unknown label, exactly as `delete_saved_query` does.
pub async fn delete_tag_label(state: &AppState, label_id: String) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::delete_tag_label(&db, &label_id)
        .map_err(|e| format!("Failed to delete tag label: {}", e))
}

// ---------------------------------------------------------------------------
// Row tags
// ---------------------------------------------------------------------------

pub async fn load_row_tags(
    state: &AppState,
    connection_id: String,
) -> Result<Vec<RowTag>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_row_tags(&db, &connection_id)
        .map_err(|e| format!("Failed to load row tags: {}", e))
}

/// The CRUD mints the tag id AND opens its own transaction. So no id is made
/// here, and nothing wraps the call: a second `BEGIN` on this connection would
/// be refused.
pub async fn upsert_row_tag(state: &AppState, upsert: UpsertRowTag) -> Result<RowTag, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::upsert_row_tag(&db, &upsert).map_err(|e| format!("Failed to save row tag: {}", e))
}

pub async fn delete_row_tag(state: &AppState, tag_id: String) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::delete_row_tag(&db, &tag_id).map_err(|e| format!("Failed to delete row tag: {}", e))
}

/// The count is the number of rows actually removed, which can be fewer than
/// `tag_ids.len()`. Like `upsert_row_tag`, the CRUD holds its own transaction.
pub async fn delete_row_tags(
    state: &AppState,
    tag_ids: Vec<String>,
) -> Result<usize, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::delete_row_tags(&db, &tag_ids)
        .map_err(|e| format!("Failed to delete row tags: {}", e))
}
