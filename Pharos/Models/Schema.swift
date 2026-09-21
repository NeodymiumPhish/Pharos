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

/// Which mechanism gives a parent its children. Declarative partitioning
/// (PostgreSQL 10 and later) has a strategy, a key and a bound per child;
/// legacy inheritance has none of the three, so the two cannot share a
/// badge, an inspector field, or a DDL clause.
enum PartitionMechanism: String, Codable {
    case declarative
    case inheritance

    /// Short uppercase badge label. Declarative shows its strategy instead
    /// (RANGE / LIST / HASH), so only inheritance ever reads this — and it
    /// reads the SQL keyword that made the tree, not the enum's own name.
    var badgeLabel: String {
        switch self {
        case .declarative: return "PARTITION"
        case .inheritance: return "INHERITS"
        }
    }
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
    /// Which mechanism gives this row its children, when it has any.
    let partitionMechanism: PartitionMechanism?
    /// True when other tables INHERIT from this one, whatever the Navigator
    /// is set to show. `TRUNCATE` has no `ONLY`, so it empties every one of
    /// them: the confirmation reads this, not the display fact above.
    let hasChildTables: Bool
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly

    enum CodingKeys: String, CodingKey {
        case name, schemaName, tableType, rowCountEstimate, totalSizeBytes
        case isPartitioned, isPartition, partitionStrategy, partitionKey, partitionBound, partitionCount
        case partitionMechanism, hasChildTables
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
        // Soft-decode, as with the strategy above: an unknown mechanism must
        // not fail the whole table-list decode.
        partitionMechanism = (try c.decodeIfPresent(String.self, forKey: .partitionMechanism))
            .flatMap(PartitionMechanism.init(rawValue:))
        hasChildTables = try c.decodeIfPresent(Bool.self, forKey: .hasChildTables) ?? false
    }

    /// Memberwise init for tests / in-code construction.
    init(name: String, schemaName: String, tableType: TableType,
         rowCountEstimate: Int64?, totalSizeBytes: Int64?,
         isPartitioned: Bool = false, isPartition: Bool = false,
         partitionStrategy: PartitionStrategy? = nil, partitionKey: String? = nil,
         partitionBound: String? = nil, partitionCount: Int64? = nil,
         partitionMechanism: PartitionMechanism? = nil,
         hasChildTables: Bool = false) {
        self.name = name; self.schemaName = schemaName; self.tableType = tableType
        self.rowCountEstimate = rowCountEstimate; self.totalSizeBytes = totalSizeBytes
        self.isPartitioned = isPartitioned; self.isPartition = isPartition
        self.partitionStrategy = partitionStrategy; self.partitionKey = partitionKey
        self.partitionBound = partitionBound; self.partitionCount = partitionCount
        self.partitionMechanism = partitionMechanism
        self.hasChildTables = hasChildTables
    }
}

extension TableInfo {
    /// Whether this parent is given a Partitions folder in the Navigator.
    ///
    /// A declarative parent is gated by Settings ▸ Navigator ▸ Show leaf
    /// partitions, as it always was. An inheritance parent is NOT: with
    /// Group inherited tables on, its children have already left the top
    /// level of the schema, so the folder is the only way to reach them.
    ///
    /// The same test decides whether the parent is given the filter index —
    /// a name that cannot be opened must not be findable either.
    func hasPartitionsFolder(showLeafPartitions: Bool) -> Bool {
        guard isPartitioned else { return false }
        if partitionMechanism == .inheritance { return true }
        return showLeafPartitions
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

/// Which rows a clone takes when the source has descendants.
///
/// The copy is always a standalone table, so on a parent these two are very
/// different amounts of data: measured on PostgreSQL 16.14, a three-level
/// inheritance parent answered 1 row under `ownRows` and 4 under `wholeTree`.
/// On the archive that prompted this the second reads 4,700 tables. Mirrors
/// `CloneRowScope` in pharos-core's `table.rs`; the raw values are what
/// `JSONEncoder.pharos` puts on the wire, and it sets no key strategy.
enum CloneRowScope: String, Codable, CaseIterable {
    /// `FROM ONLY` — the rows stored in this table itself.
    case ownRows
    /// This table's rows and every descendant's, flattened into the copy.
    case wholeTree

    var title: String {
        switch self {
        case .ownRows: return "This table's rows only"
        case .wholeTree: return "The whole tree, flattened"
        }
    }
}

struct CloneTableOptions: Codable {
    let sourceSchema: String
    let sourceTable: String
    let targetSchema: String
    let targetTable: String
    let includeData: Bool
    /// Ignored unless `includeData`.
    let rowScope: CloneRowScope
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
