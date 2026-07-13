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
    var isPartitioned: Bool = false
    var isPartition: Bool = false
    var partitionStrategy: PartitionStrategy?
    var partitionKey: String?       // raw pg_get_partkeydef, e.g. "RANGE (created_at)"
    var partitionBound: String?     // pg_get_expr(relpartbound) or "DEFAULT"
    var partitionCount: Int64?
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
        partitionStrategy = try c.decodeIfPresent(PartitionStrategy.self, forKey: .partitionStrategy)
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

enum ExportFormat: String, Codable, CaseIterable {
    case csv = "csv"
    case tsv = "tsv"
    case json = "json"
    case jsonLines = "jsonLines"
    case sqlInsert = "sqlInsert"
    case markdown = "markdown"
    case xlsx = "xlsx"

    var displayLabel: String {
        switch self {
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .json: return "JSON"
        case .jsonLines: return "JSON Lines"
        case .sqlInsert: return "SQL INSERT"
        case .markdown: return "Markdown"
        case .xlsx: return "Excel (XLSX)"
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .json: return "json"
        case .jsonLines: return "jsonl"
        case .sqlInsert: return "sql"
        case .markdown: return "md"
        case .xlsx: return "xlsx"
        }
    }
}

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
}

struct ExportTableResult: Codable {
    let success: Bool
    let rowsExported: UInt64
}

struct ImportCsvOptions: Codable {
    let schemaName: String
    let tableName: String
    let filePath: String
    let hasHeaders: Bool
}

struct ImportCsvResult: Codable {
    let success: Bool
    let rowsImported: UInt64
}
