use serde::{Deserialize, Serialize};

/// One editor tab as it was left at the end of the last run.
///
/// A tab that has executed a query owns a `workspace_id`; its editor text,
/// variables and cursor live in the `workspaces` row as well, and the workspace
/// copy is the authoritative one on restore. The copies kept here let a draft
/// tab — one that never ran — come back too, and let a restore still show
/// something when the workspace row has been deleted.
///
/// `#[serde(rename_all = "camelCase")]`: the Swift decoder applies no key
/// strategy, so the JSON keys here are exactly the Swift property names.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionTab {
    /// Position in the tab bar, 0-based. Also the primary key of the row.
    pub tab_index: i64,
    pub workspace_id: Option<String>,
    pub name: String,
    /// True when the user named the tab, false when the name is the generated
    /// "Query <n>". Mirrors the same flag on a workspace row.
    #[serde(default)]
    pub name_is_custom: bool,
    pub connection_id: Option<String>,
    pub schema_name: Option<String>,
    #[serde(default)]
    pub sql: String,
    #[serde(default)]
    pub cursor_position: i64,
    pub variables_json: Option<String>,
    #[serde(default)]
    pub is_active: bool,
}

/// The whole set of open tabs, ordered by `tab_index`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    #[serde(default)]
    pub tabs: Vec<SessionTab>,
}
