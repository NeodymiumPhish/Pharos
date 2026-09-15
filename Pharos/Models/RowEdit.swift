import Foundation

/// The request the grid sends to the core to apply pending cell edits: one
/// table, one key, N rows. Every value crosses as text (PostgreSQL text form;
/// `nil` is SQL NULL) and is BOUND on the Rust side with the column's own
/// data type — nothing here is ever spliced into SQL. Positions in
/// `rows[i].oldValues` / `newValues` align with `columns`; positions in
/// `rows[i].key` align with `keyColumns`.
///
/// Rust mirror: `pharos-core/src/commands/row_edit.rs` (`#[serde(rename_all = "camelCase")]`).
struct RowUpdateRequest: Codable, Equatable {
    struct Column: Codable, Equatable {
        let name: String
        let dataType: String
    }
    struct Row: Codable, Equatable {
        /// Key values, aligned with `keyColumns`; never nil (a NULL key is not editable).
        let key: [String]
        /// The values as loaded, aligned with `columns`; they go into the WHERE
        /// clause (`IS NOT DISTINCT FROM`) so a concurrent change matches 0 rows.
        let oldValues: [String?]
        /// The values to write, aligned with `columns`.
        let newValues: [String?]
    }
    let schema: String
    let table: String
    /// The key the rows are matched on: the primary key, or a NOT NULL unique index.
    let keyColumns: [Column]
    /// A user-facing name for the key: "primary key" or "unique index (email)".
    let keyDescription: String
    /// The edited columns, in statement order.
    let columns: [Column]
    let rows: [Row]
}

/// The core's answer after the transaction committed.
struct RowUpdateResult: Codable, Equatable {
    let rowsUpdated: Int
    let executionTimeMs: UInt64
    /// The query-history row the write was recorded under, if the core recorded one.
    let historyEntryId: String?
}
