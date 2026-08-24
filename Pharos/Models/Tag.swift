import Foundation

// The Rust tag models in `pharos-core/src/models/tag.rs` all carry
// `#[serde(rename_all = "camelCase")]`, and JSONDecoder/Encoder.pharos apply NO
// key strategy, so these Swift structs use plain camelCase property names
// (matching the JSON keys exactly) with NO CodingKeys. Do not add snake_case
// CodingKeys here.
//
// The OPPOSITE rule applies to the result models — see `ColumnDef` in
// Pharos/Models/QueryResult.swift, whose Rust structs carry no `rename_all` and
// therefore DO need CodingKeys. The two conventions sit side by side on
// purpose; a mismatch throws at run time only, so TagModelTests pins this one.

/// One captured value.
///
/// `column` is PROVENANCE and never takes part in matching — the design's
/// Matching section is explicit that column names are shown, not compared.
/// `value` is the normalized form `TagValueNormalizer` produced; `display` is
/// the text as captured, for the Inspector.
struct TagCondition: Codable, Equatable {
    let column: String
    /// "address" | "text" | "numeric" | "temporal" | "uuid" | "type:<name>"
    let family: String
    let value: String
    let display: String
}

/// One tagged origin row. Its values are the tuple the matcher tests.
struct TagRule: Codable, Equatable, Identifiable {
    let id: String
    let conditions: [TagCondition]
    let tupleKey: String
    let originConnection: String
    let originTable: String
    let createdAt: String
}

/// A named indicator set: a case name, a colour, a note, and the tuples that
/// define the finding. Global — a tag carries no connection id.
struct Tag: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    /// Index into `TagPalette.colors`, not a hex string.
    var colorIndex: Int
    var note: String?
    let createdAt: String
    let updatedAt: String
    var rules: [TagRule]
}

/// A tuple as Swift sends it. Rust mints the id and the timestamp.
struct NewTagRule: Codable, Equatable {
    var conditions: [TagCondition]
    /// `RuleKey.encode` is the only producer. Rust never builds one.
    var tupleKey: String
    var originConnection: String
    var originTable: String
}

struct CreateTag: Codable {
    var name: String
    var colorIndex: Int
    var note: String?
    var rules: [NewTagRule]
}

struct AddTagRules: Codable {
    var tagId: String
    var rules: [NewTagRule]
}

/// A nil field is left as it is. A note cannot be CLEARED through this payload,
/// only replaced — write an empty string for "no note".
struct UpdateTag: Codable {
    var id: String
    var name: String?
    var colorIndex: Int?
    var note: String?
}
