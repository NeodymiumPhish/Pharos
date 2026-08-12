import Foundation

// The Rust structs behind ColumnDef, KeySet, RowIdentity and QueryResult carry
// NO `#[serde(rename_all)]`, so their JSON keys are snake_case and every field
// whose Swift name differs needs an explicit CodingKeys case. JSONDecoder.pharos
// applies no key strategy, so a missing case throws at RUN time only.
// The row TAG models take the opposite rule — see Pharos/Models/RowTag.swift.

struct ColumnDef: Codable {
    let name: String
    let dataType: String
    /// OID of the source table, or nil for an expression column. Also nil for a
    /// column decoded from history cached before this field existed, so it must
    /// stay optional: Swift is the only decoder of that cached JSON.
    let relationOid: UInt32?
    /// 1-based attnum in that table, or nil as above.
    let relationAttno: Int16?

    enum CodingKeys: String, CodingKey {
        case name
        case dataType = "data_type"
        case relationOid = "relation_oid"
        case relationAttno = "relation_attno"
    }

    /// The OID pair defaults to nil so the many call sites that build a synthetic
    /// column (chart/drill test fixtures, pushdown generators) keep the
    /// two-argument form. A synthetic column genuinely has no source table, so
    /// nil is the right value there, not a placeholder.
    init(name: String, dataType: String, relationOid: UInt32? = nil, relationAttno: Int16? = nil) {
        self.name = name
        self.dataType = dataType
        self.relationOid = relationOid
        self.relationAttno = relationAttno
    }
}

/// One satisfied key of a result. `keys` holds one string per row, in row order.
/// An empty string means the row has no identity in this set, for example a NULL
/// key value from an outer join.
struct KeySet: Codable {
    /// "pk" or "unique"
    let kind: String
    let keyColumns: [String]
    let keys: [String]

    enum CodingKeys: String, CodingKey {
        case kind
        case keyColumns = "key_columns"
        case keys
    }
}

/// The row identity of a result. An empty `candidates` array means the
/// fingerprint tier.
struct RowIdentity: Codable {
    let tableKey: String
    let tableDisplay: String
    /// Every source table in the result, for the fingerprint overlap test.
    let tableKeys: [String]
    /// At most two entries, strongest first.
    let candidates: [KeySet]

    enum CodingKeys: String, CodingKey {
        case tableKey = "table_key"
        case tableDisplay = "table_display"
        case tableKeys = "table_keys"
        case candidates
    }
}

extension RowIdentity {
    /// Extend this block to cover rows appended by a later page.
    ///
    /// `keys` is PER ROW, so a Load More that concatenates rows must concatenate
    /// keys as well. Taking either block wholesale leaves keys misaligned with
    /// rows: page 1's block covers only page 1, and page 2's covers only page 2.
    /// A misalignment is worse than a gap, because row N would take row M's tag.
    ///
    /// When the later page carries no block, or carries a candidate this block
    /// does not have, the new rows get the empty-string sentinel — the same
    /// marker the core uses for "this row has no identity". That is honest: the
    /// rows exist, and nothing is known about their keys.
    func appendingPage(_ page: RowIdentity?, pageRowCount: Int) -> RowIdentity {
        let extended = candidates.map { mine -> KeySet in
            let theirs = page?.candidates.first { $0.kind == mine.kind && $0.keyColumns == mine.keyColumns }
            let tail = theirs?.keys ?? []
            // Pad or trim so the tail is exactly the number of appended rows.
            let aligned = tail.count == pageRowCount
                ? tail
                : tail.prefix(pageRowCount) + Array(repeating: "", count: max(0, pageRowCount - tail.count))
            return KeySet(kind: mine.kind, keyColumns: mine.keyColumns, keys: mine.keys + Array(aligned))
        }
        return RowIdentity(
            tableKey: tableKey,
            tableDisplay: tableDisplay,
            tableKeys: tableKeys,
            candidates: extended
        )
    }
}

struct QueryResult: Codable {
    let columns: [ColumnDef]
    let rows: [[AnyCodable]]
    let rowCount: Int
    let executionTimeMs: UInt64
    let hasMore: Bool
    let historyEntryId: String?
    /// nil when no column carries a source table, and on the empty page of a
    /// Load More. A consumer must KEEP the block it already holds when a later
    /// page carries nil: the empty branch of `fetch_more_rows` returns no
    /// columns, so it can carry no identity. Replacing a block with nil would
    /// drop every tag in the grid.
    let rowIdentity: RowIdentity?

    enum CodingKeys: String, CodingKey {
        case columns, rows
        case rowCount = "row_count"
        case executionTimeMs = "execution_time_ms"
        case hasMore = "has_more"
        case historyEntryId = "history_entry_id"
        case rowIdentity = "row_identity"
    }

    /// `rowIdentity` defaults to nil so the existing hand-built results keep
    /// their current call form.
    ///
    /// WARNING: `rowIdentity` defaults to nil so that existing call sites keep
    /// compiling, and that default is a trap for any code that MERGES one result
    /// into another. Row keys are per row, so a merge must concatenate them with
    /// `RowIdentity.appendingPage(_:pageRowCount:)`; taking the default drops
    /// every tag, and copying either block wholesale misaligns keys against rows.
    /// The two Load More merges in ContentViewController (`loadMoreRows` and the
    /// chart load-all loop) already do this correctly — follow them.
    init(
        columns: [ColumnDef],
        rows: [[AnyCodable]],
        rowCount: Int,
        executionTimeMs: UInt64,
        hasMore: Bool,
        historyEntryId: String?,
        rowIdentity: RowIdentity? = nil
    ) {
        self.columns = columns
        self.rows = rows
        self.rowCount = rowCount
        self.executionTimeMs = executionTimeMs
        self.hasMore = hasMore
        self.historyEntryId = historyEntryId
        self.rowIdentity = rowIdentity
    }
}

struct ExecuteResult: Codable {
    let rowsAffected: UInt64
    let executionTimeMs: UInt64
    /// History entry id for this statement, so it can be associated with a workspace.
    let historyEntryId: String?

    enum CodingKeys: String, CodingKey {
        case rowsAffected = "rows_affected"
        case executionTimeMs = "execution_time_ms"
        case historyEntryId = "history_entry_id"
    }
}

struct ValidationResult: Codable {
    let valid: Bool
    let error: ValidationError?
}

struct ValidationError: Codable {
    let message: String
    let position: Int?
}

// MARK: - AnyCodable (for heterogeneous JSON values)

/// A type-erased Codable value for representing arbitrary JSON.
struct AnyCodable: Codable {
    let value: Any?

    /// Construct directly from a value (tests, ChartData assembly).
    init(_ value: Any?) {
        self.value = value
    }

    /// The cell as text, or nil for a SQL NULL.
    ///
    /// Every value of a real result crosses the FFI as a JSON string, because the
    /// core reads PostgreSQL's text format — so `decode(Bool)`, `decode(Int64)` and
    /// `decode(Double)` in `init(from:)` all fail on it and the value lands in the
    /// `String` branch. A non-string here is therefore a hand-built fixture (a
    /// chart or drill test), never a row a user could tag, and nil is the honest
    /// answer for it rather than a `String(describing:)` that would invent a
    /// format the fingerprint then depends on.
    var stringValue: String? {
        value as? String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int64.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case nil:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int64:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        default:
            try container.encodeNil()
        }
    }

    /// Get the value as a display string.
    var displayString: String {
        switch value {
        case nil: return ""
        case let bool as Bool: return bool ? "true" : "false"
        case let int as Int64: return String(int)
        case let double as Double: return String(double)
        case let string as String: return string
        default: return String(describing: value ?? "")
        }
    }

    var isNull: Bool { value == nil }
}
