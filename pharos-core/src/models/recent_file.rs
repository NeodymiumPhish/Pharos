use serde::{Deserialize, Serialize};

/// One entry of the Files navigator: a DuckDB database or a data file (CSV,
/// Parquet, JSON, Excel) the user opened, and when they last did.
///
/// The list has no limit, unlike the system's recent documents (File ▸ Open
/// Recent, the Dock), which keep only the newest few. `kind` is an opaque
/// string ("duckdb" or "data") that Swift owns. `last_opened_at` is an
/// ISO 8601 UTC time ("2026-10-22T16:02:00Z"), so the newest compares
/// greatest as text. Keys are camelCase: `JSONDecoder.pharos` applies no key
/// strategy.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RecentFile {
    pub path: String,
    pub kind: String,
    pub last_opened_at: String,
}
