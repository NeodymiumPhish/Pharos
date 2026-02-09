use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchemaInfo {
    pub name: String,
    pub owner: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TableType {
    Table,
    View,
    #[serde(rename = "foreign-table")]
    ForeignTable,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableInfo {
    pub name: String,
    pub schema_name: String,
    pub table_type: TableType,
    pub row_count_estimate: Option<i64>,
    pub total_size_bytes: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalyzeResult {
    pub had_unanalyzed: bool,
    pub permission_denied_tables: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnInfo {
    pub name: String,
    pub data_type: String,
    pub is_nullable: bool,
    pub is_primary_key: bool,
    pub ordinal_position: i32,
    pub column_default: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexInfo {
    pub name: String,
    pub columns: Vec<String>,
    pub is_unique: bool,
    pub is_primary: bool,
    pub index_type: String,
    pub size_bytes: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConstraintInfo {
    pub name: String,
    pub constraint_type: String,
    pub columns: Vec<String>,
    pub referenced_table: Option<String>,
    pub referenced_columns: Option<Vec<String>>,
    pub check_clause: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FunctionInfo {
    pub name: String,
    pub schema_name: String,
    pub return_type: String,
    pub argument_types: String,
    pub function_type: String,
    pub language: String,
}
