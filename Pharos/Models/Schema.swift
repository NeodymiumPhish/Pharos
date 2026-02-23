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
