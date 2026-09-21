use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchemaInfo {
    pub name: String,
    pub owner: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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

/// Which mechanism gives a parent its children. Declarative partitioning
/// (PostgreSQL 10 and later) has a strategy, a key and a bound per child;
/// legacy inheritance has none of the three, so the two cannot share a
/// badge, an inspector field, or a DDL clause.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PartitionMechanism {
    Declarative,
    Inheritance,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableInfo {
    pub name: String,
    pub schema_name: String,
    pub table_type: TableType,
    pub row_count_estimate: Option<i64>,
    pub total_size_bytes: Option<i64>,
    /// True when this relation is a parent with a Partitions folder: a
    /// declarative parent (relkind='p'), or — with Settings ▸ Navigator ▸
    /// Group inherited tables on — a table that other tables INHERIT from.
    /// `partition_mechanism` says which.
    #[serde(default)]
    pub is_partitioned: bool,
    /// True when this relation is itself a partition of some parent.
    #[serde(default)]
    pub is_partition: bool,
    /// Present when `is_partitioned`.
    #[serde(default)]
    pub partition_strategy: Option<PartitionStrategy>,
    /// Raw `pg_get_partkeydef` output, e.g. "RANGE (created_at)". Present when `is_partitioned`.
    #[serde(default)]
    pub partition_key: Option<String>,
    /// This partition's bound text from `pg_get_expr(relpartbound)`, or "DEFAULT". Present when `is_partition`.
    #[serde(default)]
    pub partition_bound: Option<String>,
    /// Number of direct child partitions. Present when `is_partitioned`.
    #[serde(default)]
    pub partition_count: Option<i64>,
    /// Which mechanism gives this relation its children. Present when
    /// `is_partitioned`.
    #[serde(default)]
    pub partition_mechanism: Option<PartitionMechanism>,
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

    /// Swift's `JSONDecoder.pharos` applies no key strategy and soft-decodes
    /// this one from a string, so the spelling on the wire is the contract.
    #[test]
    fn the_mechanism_crosses_the_wire_in_lower_case() {
        let json = serde_json::to_string(&PartitionMechanism::Inheritance).unwrap();
        assert_eq!(json, "\"inheritance\"");
        let json = serde_json::to_string(&PartitionMechanism::Declarative).unwrap();
        assert_eq!(json, "\"declarative\"");
    }

    /// A parent with no mechanism leaves the key out, and an older core that
    /// never sends it still decodes here.
    #[test]
    fn the_mechanism_is_optional_in_both_directions() {
        let table = TableInfo {
            name: "logs".into(),
            schema_name: "public".into(),
            table_type: TableType::Table,
            row_count_estimate: Some(5),
            total_size_bytes: Some(8192),
            is_partitioned: true,
            is_partition: false,
            partition_strategy: None,
            partition_key: None,
            partition_bound: None,
            partition_count: Some(2),
            partition_mechanism: Some(PartitionMechanism::Inheritance),
        };
        let json = serde_json::to_string(&table).unwrap();
        assert!(json.contains("\"partitionMechanism\":\"inheritance\""), "{json}");
        // The key is absent: `#[serde(default)]` fills it in.
        let older = json.replace(",\"partitionMechanism\":\"inheritance\"", "");
        let back: TableInfo = serde_json::from_str(&older).unwrap();
        assert_eq!(back.partition_mechanism, None);
        assert!(back.is_partitioned);
    }
}
