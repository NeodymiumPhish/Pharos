import Foundation

struct SchemaInfo: Codable {
    let name: String
    let owner: String?
}

enum TableType: String, Codable {
    case table
    case view
    case foreignTable = "foreign-table"
}

struct TableInfo: Codable {
    let name: String
    let schemaName: String
    let tableType: TableType
    let rowCountEstimate: Int64?
    let totalSizeBytes: Int64?
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly
}

struct AnalyzeResult: Codable {
    let hadUnanalyzed: Bool
    let permissionDeniedTables: [String]
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
