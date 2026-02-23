import Foundation

struct ColumnDef: Codable {
    let name: String
    let dataType: String

    enum CodingKeys: String, CodingKey {
        case name
        case dataType = "data_type"
    }
}

struct QueryResult: Codable {
    let columns: [ColumnDef]
    let rows: [[String: AnyCodable]]
    let rowCount: Int
    let executionTimeMs: UInt64
    let hasMore: Bool
    let historyEntryId: String?

    enum CodingKeys: String, CodingKey {
        case columns, rows
        case rowCount = "row_count"
        case executionTimeMs = "execution_time_ms"
        case hasMore = "has_more"
        case historyEntryId = "history_entry_id"
    }
}

struct ExecuteResult: Codable {
    let rowsAffected: UInt64
    let executionTimeMs: UInt64

    enum CodingKeys: String, CodingKey {
        case rowsAffected = "rows_affected"
        case executionTimeMs = "execution_time_ms"
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

    init(_ value: Any?) {
        self.value = value
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
