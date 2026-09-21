import Foundation

/// One schema-qualified name, exactly as the server spells it: NOT quoted and
/// NOT escaped.
///
/// It is shown in the sheet's own prose, so the caller escapes it per part
/// with `DisplayEscape.escapedQualified` — the same treatment the sheet's
/// subtitle gets. Mirrors `QualifiedName` in pharos-core's `ddl.rs`.
struct QualifiedTableName: Codable, Equatable {
    let schema: String
    let table: String
}

/// What a table's shape means for CLONING it, sent alongside the DDL.
///
/// `LIKE ... INCLUDING ALL` carries neither `PARTITION BY` nor `INHERITS`, so
/// these three facts decide what the copy can be and which rows it may take.
/// Mirrors `TableShape` in pharos-core's `ddl.rs`.
struct TableShape: Codable, Equatable {
    /// The partition clause the copy carries, e.g. "RANGE (created_at)".
    /// Non-nil means the copy is created with no partitions and can hold no rows.
    let partitionBy: String?
    /// The parents this table inherits from. The copy will NOT inherit from
    /// them — it is standalone.
    let inheritsFrom: [QualifiedTableName]
    /// Whether descendants exist, and so whether the row scope is a real
    /// choice rather than one answer under two names.
    let hasChildTables: Bool
    /// The parent this table is a declarative partition of. The copy will NOT
    /// be attached to it — `LIKE ... INCLUDING ALL` carries no attachment,
    /// exactly as it carries no `INHERITS`, so the copy stands alone.
    let partitionOf: QualifiedTableName?

    /// A declarative parent: the copy keeps the partition key and starts with
    /// no partitions, so rows cannot go into it at all.
    var isPartitionedParent: Bool { partitionBy != nil }
}

/// The three reconstructed CREATE TABLE DDL variants returned by the core,
/// with the shape facts the clone action needs.
struct TableDDL: Codable {
    let columnsOnly: String
    let withConstraints: String
    let full: String
    let shape: TableShape
}

/// Selectable level of DDL detail shown in the TableDDLSheet sidebar.
enum DDLDetailLevel: Int, CaseIterable {
    case columns = 0
    case constraints = 1
    case full = 2

    var title: String {
        switch self {
        case .columns: return "Columns"
        case .constraints: return "+ Constraints"
        case .full: return "Full (+ Indexes)"
        }
    }

    func ddl(from ddl: TableDDL) -> String {
        switch self {
        case .columns: return ddl.columnsOnly
        case .constraints: return ddl.withConstraints
        case .full: return ddl.full
        }
    }
}
