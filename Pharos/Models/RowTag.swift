import Foundation

// The Rust row tag models in `pharos-core/src/models/row_tag.rs` all carry
// `#[serde(rename_all = "camelCase")]`, and JSONDecoder/Encoder.pharos apply NO
// key strategy, so these Swift structs use plain camelCase property names
// (matching the JSON keys exactly) with NO CodingKeys. Do not add snake_case
// CodingKeys here. Pharos/Models/Workspace.swift states the same rule for the
// workspace models.
//
// The OPPOSITE rule applies to the row identity carried on a result — see
// `RowIdentity` in Pharos/Models/QueryResult.swift. Those Rust structs carry no
// `rename_all`, so their keys are snake_case and they DO need CodingKeys. The
// two conventions sit side by side on purpose; a mismatch throws at run time
// only, so PharosTests/RowTagModelTests.swift pins both.

// MARK: - Labels

/// A re-usable label. The palette is global: a label holds no connection id.
struct TagLabel: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    /// Index into a fixed colour palette, not a hex string.
    var colorIndex: Int
    var sortOrder: Int
    let createdAt: String
}

/// Payload to create a label. Rust assigns the id, sort order and timestamp.
struct CreateTagLabel: Codable {
    var name: String
    var colorIndex: Int
}

/// Payload to change a label. A nil field is left as it is.
struct UpdateTagLabel: Codable {
    var id: String
    var name: String?
    var colorIndex: Int?
    var sortOrder: Int?
}

// MARK: - Tags

/// One candidate key of a tagged row. A strong tag holds one or two of these.
/// A fingerprint tag holds exactly one.
struct RowTagKey: Codable, Equatable {
    /// "pk" | "unique" | "fingerprint"
    let identityKind: String
    /// The canonical compare string, as built by `encode_key` in
    /// `pharos-core/src/commands/row_identity.rs`. Treat it as opaque: never
    /// parse it or build one in Swift.
    let identityValue: String
}

/// A stored tag on one row.
struct RowTag: Codable, Identifiable, Equatable {
    let id: String
    let connectionId: String
    var labelId: String
    var note: String?
    /// The strongest kind this tag holds. Display only: it drives the trust
    /// sentence in the popover.
    let primaryKind: String
    /// "oid:16543", or "name:public.users" when the result carried no OID.
    let tableKey: String
    let tableDisplay: String
    /// The primary candidate's columns, or every column for a fingerprint tag.
    let identityColumns: [String]
    /// The matching values, positionally aligned with `identityColumns`.
    /// A nil element is a NULL — not an empty string.
    let identityValues: [String?]
    let keys: [RowTagKey]
    let createdAt: String
    let updatedAt: String
}

/// Payload for a tag write. The write is key-set-aware: Rust replaces any tag
/// that already matches ANY key in `keys`.
///
/// Swift is the only producer of this type, so nothing on the Rust side can
/// catch a casing mistake in it — a snake_case key would reach serde as an
/// unknown field and the real field would be reported missing at run time.
/// PharosTests/RowTagModelTests.swift asserts on the encoded wire text.
struct UpsertRowTag: Codable {
    var connectionId: String
    var labelId: String
    var note: String?
    var primaryKind: String
    var tableKey: String
    var tableDisplay: String
    var identityColumns: [String]
    /// A nil element is a NULL. Positionally aligned with `identityColumns`.
    var identityValues: [String?]
    var keys: [RowTagKey]
}
