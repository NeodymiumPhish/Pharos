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
    #[serde(rename = "partitioned-table")]
    PartitionedTable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PartitionStrategy {
    Range,
    List,
    Hash,
}

impl PartitionStrategy {
    /// Map `pg_partitioned_table.partstrat` ('r' | 'l' | 'h') to a strategy.
    pub fn from_pg_char(c: char) -> Option<PartitionStrategy> {
        match c {
            'r' => Some(PartitionStrategy::Range),
            'l' => Some(PartitionStrategy::List),
            'h' => Some(PartitionStrategy::Hash),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableInfo {
    pub name: String,
    pub schema_name: String,
    pub table_type: TableType,
    pub row_count_estimate: Option<i64>,
    pub total_size_bytes: Option<i64>,
    #[serde(default)]
    pub is_partitioned: bool,
    #[serde(default)]
    pub is_partition: bool,
    #[serde(default)]
    pub partition_strategy: Option<PartitionStrategy>,
    #[serde(default)]
    pub partition_key: Option<String>,
    #[serde(default)]
    pub partition_bound: Option<String>,
    #[serde(default)]
    pub partition_count: Option<i64>,
}

/// Minimal parent→child pairing used to populate the sidebar filter index
/// without eagerly fetching full partition detail.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PartitionRef {
    pub parent_name: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalyzeResult {
    pub had_unanalyzed: bool,
    pub permission_denied_tables: Vec<String>,
    /// Refreshed table metadata for the analyzed schema. Bundled into this
    /// response so callers don't need a second `getTables` round-trip after
    /// every analyze — that was the cost of a "refresh row counts" tick.
    pub tables: Vec<TableInfo>,
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
pub struct SchemaColumnInfo {
    pub table_name: String,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strategy_from_pg_char() {
        assert_eq!(PartitionStrategy::from_pg_char('r'), Some(PartitionStrategy::Range));
        assert_eq!(PartitionStrategy::from_pg_char('l'), Some(PartitionStrategy::List));
        assert_eq!(PartitionStrategy::from_pg_char('h'), Some(PartitionStrategy::Hash));
        assert_eq!(PartitionStrategy::from_pg_char('x'), None);
    }
}
