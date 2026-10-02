use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedQuery {
    pub id: String,
    pub name: String,
    pub folder: Option<String>,
    pub sql: String,
    pub connection_id: Option<String>,
    pub variables: Option<String>,
    /// The query's cards as JSON (Swift's `CardPersistence`): a saved query is
    /// a whole tab of cards. `sql` holds the latest version of each as text.
    #[serde(default)]
    pub cards_json: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateSavedQuery {
    pub name: String,
    pub folder: Option<String>,
    pub sql: String,
    pub connection_id: Option<String>,
    pub variables: Option<String>,
    #[serde(default)]
    pub cards_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSavedQuery {
    pub id: String,
    pub name: Option<String>,
    pub folder: Option<String>,
    pub sql: Option<String>,
    pub variables: Option<String>,
    /// None leaves the stored cards alone.
    #[serde(default)]
    pub cards_json: Option<String>,
}
