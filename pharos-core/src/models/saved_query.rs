use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedQuery {
    pub id: String,
    pub name: String,
    pub folder: Option<String>,
    pub sql: String,
    pub connection_id: Option<String>,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSavedQuery {
    pub id: String,
    pub name: Option<String>,
    pub folder: Option<String>,
    pub sql: Option<String>,
}
