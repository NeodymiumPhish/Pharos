import Foundation

/// What "Describe a query" adds to the cached catalogue for one schema:
/// foreign keys, enum labels, the real names of types information_schema
/// reports as USER-DEFINED or ARRAY, and short comments.
///
/// Mirrors `SchemaDraftFacts` in pharos-core/src/models/schema.rs, whose
/// serde names are camelCase with `type` for the type fields. Rust always
/// writes every key, so the synthesized decoder is enough. Names, types,
/// keys and comments only: the query that fills it reads no column default
/// and no CHECK clause, because both can hold literal values.
struct SchemaDraftFacts: Codable, Equatable, Sendable {

    struct Column: Codable, Equatable, Sendable {
        let table: String
        let name: String
        /// `format_type`: `sales.order_status`, `integer[]`, `numeric(10,2)`.
        let type: String
        let comment: String?
    }

    struct ForeignKey: Codable, Equatable, Sendable {
        let table: String
        let columns: [String]
        let refSchema: String
        let refTable: String
        let refColumns: [String]
    }

    struct EnumType: Codable, Equatable, Sendable {
        /// `format_type` of the enum, matching `Column.type`.
        let type: String
        /// At most 20, in sort order.
        let labels: [String]
    }

    /// Table name → comment, cut to 80 characters.
    var tableComments: [String: String] = [:]
    /// Only columns whose type information_schema cannot name, or that carry
    /// a comment.
    var columns: [Column] = []
    var foreignKeys: [ForeignKey] = []
    var enums: [EnumType] = []
}
