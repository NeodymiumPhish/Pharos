import Foundation

struct SchemaInfo: Codable {
    let name: String
    let owner: String?
}

enum TableType: String, Codable {
    case table
    case view
    case foreignTable = "foreign-table"
    case partitionedTable = "partitioned-table"
}

enum PartitionStrategy: String, Codable {
    case range
    case list
    case hash

    /// Short uppercase badge label: RANGE / LIST / HASH.
    var badgeLabel: String { rawValue.uppercased() }
}

struct TableInfo: Codable {
    let name: String
    let schemaName: String
    let tableType: TableType
    let rowCountEstimate: Int64?
    let totalSizeBytes: Int64?
    // Partition metadata (all optional; absent/false on non-PG servers).
    let isPartitioned: Bool
    let isPartition: Bool
    let partitionStrategy: PartitionStrategy?
    let partitionKey: String?       // raw pg_get_partkeydef, e.g. "RANGE (created_at)"
    let partitionBound: String?     // pg_get_expr(relpartbound) or "DEFAULT"
    let partitionCount: Int64?
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly

    enum CodingKeys: String, CodingKey {
        case name, schemaName, tableType, rowCountEstimate, totalSizeBytes
        case isPartitioned, isPartition, partitionStrategy, partitionKey, partitionBound, partitionCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        schemaName = try c.decode(String.self, forKey: .schemaName)
        tableType = try c.decode(TableType.self, forKey: .tableType)
        rowCountEstimate = try c.decodeIfPresent(Int64.self, forKey: .rowCountEstimate)
        totalSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .totalSizeBytes)
        isPartitioned = try c.decodeIfPresent(Bool.self, forKey: .isPartitioned) ?? false
        isPartition = try c.decodeIfPresent(Bool.self, forKey: .isPartition) ?? false
        // Soft-decode: an unrecognized strategy string maps to nil rather than
        // throwing and failing the whole table-list decode.
        partitionStrategy = (try c.decodeIfPresent(String.self, forKey: .partitionStrategy))
            .flatMap(PartitionStrategy.init(rawValue:))
        partitionKey = try c.decodeIfPresent(String.self, forKey: .partitionKey)
        partitionBound = try c.decodeIfPresent(String.self, forKey: .partitionBound)
        partitionCount = try c.decodeIfPresent(Int64.self, forKey: .partitionCount)
    }

    /// Memberwise init for tests / in-code construction.
    init(name: String, schemaName: String, tableType: TableType,
         rowCountEstimate: Int64?, totalSizeBytes: Int64?,
         isPartitioned: Bool = false, isPartition: Bool = false,
         partitionStrategy: PartitionStrategy? = nil, partitionKey: String? = nil,
         partitionBound: String? = nil, partitionCount: Int64? = nil) {
        self.name = name; self.schemaName = schemaName; self.tableType = tableType
        self.rowCountEstimate = rowCountEstimate; self.totalSizeBytes = totalSizeBytes
        self.isPartitioned = isPartitioned; self.isPartition = isPartition
        self.partitionStrategy = partitionStrategy; self.partitionKey = partitionKey
        self.partitionBound = partitionBound; self.partitionCount = partitionCount
    }
}

struct PartitionRef: Codable {
    let parentName: String
    let name: String
}

struct AnalyzeResult: Codable {
    let hadUnanalyzed: Bool
    let permissionDeniedTables: [String]
    /// Refreshed table metadata bundled with the analyze result so callers
    /// can skip a follow-up getTables FFI round-trip.
    let tables: [TableInfo]
}

struct ColumnInfo: Codable {
    let name: String
    let dataType: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let ordinalPosition: Int32
    let columnDefault: String?
}

struct SchemaColumnInfo: Codable {
    let tableName: String
    let name: String
    let dataType: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let ordinalPosition: Int32
    let columnDefault: String?
}

struct IndexInfo: Codable {
    let name: String
    let columns: [String]
    let isUnique: Bool
    let isPrimary: Bool
    let indexType: String
    let sizeBytes: Int64?
}

struct ConstraintInfo: Codable {
    let name: String
    let constraintType: String
    let columns: [String]
    let referencedTable: String?
    let referencedColumns: [String]?
    let checkClause: String?
}

struct FunctionInfo: Codable {
    let name: String
    let schemaName: String
    let returnType: String
    let argumentTypes: String
    let functionType: String
    let language: String
}

// MARK: - Table Operations

// `ExportFormat` lives in `Models/Settings.swift`: `AppSettings.dataExport`
// names it, and a type `AppSettings` names has to compile with that file
// alone — see the eight standalone harnesses under `scripts/`.

struct CloneTableOptions: Codable {
    let sourceSchema: String
    let sourceTable: String
    let targetSchema: String
    let targetTable: String
    let includeData: Bool
}

struct CloneTableResult: Codable {
    let success: Bool
    let rowsCopied: Int64?
}

struct ExportTableOptions: Codable {
    let schemaName: String
    let tableName: String
    let columns: [String]
    let includeHeaders: Bool
    let nullAsEmpty: Bool
    let filePath: String
    let format: ExportFormat
    /// The CSV shape this export asks for, from `AppSettings.dataExport`.
    /// Read by the CSV/TSV branch of `stream_export` in pharos-core.
    let csv: CsvDialect
}

struct ExportTableResult: Codable {
    let success: Bool
    let rowsExported: UInt64
    /// Characters the chosen encoding could not carry and wrote as `?`.
    /// Always 0 for UTF-8 and UTF-16 LE, which carry anything.
    let charactersSubstituted: UInt64
}

struct ImportCsvOptions: Codable {
    let schemaName: String
    let tableName: String
    let filePath: String
    let hasHeaders: Bool
    /// The CSV shape to read, from `AppSettings.dataImport`.
    let csv: CsvDialect
    /// What a failing row does to the rest of the file.
    let onError: ImportErrorPolicy
    /// Rows per transaction. 0 is one transaction for the whole file.
    let commitEvery: UInt32
}

struct ImportCsvResult: Codable {
    let success: Bool
    let rowsImported: UInt64
    /// Rows rolled back to their savepoint and passed over. Always 0 under
    /// `.abort`, which has no way to reach the next row.
    let rowsSkipped: UInt64
    /// The first twenty failures, one line each. `rowsSkipped` is the
    /// complete count; this is a sample.
    let errors: [String]
    /// Transactions committed before the end of the file.
    let committedBatches: UInt64
}
