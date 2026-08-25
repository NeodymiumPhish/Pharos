import Foundation

// The Rust tag models in `pharos-core/src/models/tag.rs` all carry
// `#[serde(rename_all = "camelCase")]`, and JSONDecoder/Encoder.pharos apply NO
// key strategy, so these Swift structs use plain camelCase property names
// (matching the JSON keys exactly). Do not add snake_case CodingKeys here.
// `TagCondition` is the one type that carries CodingKeys at all, and only
// because its hand-written `init(from:)` needs them; they spell the same
// camelCase the synthesized ones would, and they list EVERY coded property.
//
// The OPPOSITE rule applies to the result models — see `ColumnDef` in
// Pharos/Models/QueryResult.swift, whose Rust structs carry no `rename_all` and
// therefore DO need CodingKeys. The two conventions sit side by side on
// purpose; a mismatch throws at run time only, so TagModelTests pins this one.

/// One condition of a rule: what to test, and what to test it against.
///
/// `value` is the NORMALIZED form and is what matching compares. `display` is
/// the text as captured or typed, byte for byte, and is what every surface
/// draws. Normalizing derives a second form beside the first; it never alters
/// what the analyst wrote.
///
/// There is deliberately NO column name here. A column never took part in
/// matching — that is what lets a hash captured under `cert_md5` resurface
/// under `certificate_hash` in another schema — and a hand-authored condition
/// has no column at all, so the FAMILY is the one description every condition
/// can share. `TagFamilyLabel` turns it into words. Row-level provenance is
/// unaffected: `originConnection` and `originTable` live on `TagRule`.
///
/// A stored blob that still carries the old `column` key decodes unchanged:
/// `CodingKeys` has no case for it, so it is ignored. No migration is needed,
/// and `TagModelTests` pins that.
///
/// The hand-written `init(from:)` is what makes `kind` and `operand2` tolerate
/// an ABSENT key, and `TagConditionKind`'s own decoder is what makes `kind`
/// tolerate an UNKNOWN VALUE. Both are needed; neither substitutes for the
/// other, and losing either destroys a rule written by a newer build.
///
/// `CodingKeys` must stay EXHAUSTIVE. Swift requires every coded property to
/// appear, and a key left out is silently dropped — the hazard
/// `memory/pharos-ffi-json-casing.md` records. There were deliberately no
/// `CodingKeys` on this type before; they exist now only because `init(from:)`
/// needs them, and they must list every property.
struct TagCondition: Codable, Equatable {
    /// "address" | "text" | "numeric" | "temporal" | "uuid" | "type:<name>"
    let family: String
    let kind: TagConditionKind
    let value: String
    /// The upper bound of a `.between`. nil for every other kind.
    ///
    /// `between` must be ONE condition rather than two comparators. Conditions
    /// in a rule are ANDed, but each is satisfied by SOME cell in the row, not
    /// the same cell — so `>= 1000` could be satisfied by one column and
    /// `<= 2000` by another, which is not a range test at all.
    let operand2: String?
    let display: String

    init(family: String, kind: TagConditionKind = .exact,
         value: String, operand2: String? = nil, display: String) {
        self.family = family
        self.kind = kind
        self.value = value
        self.operand2 = operand2
        self.display = display
    }

    private enum CodingKeys: String, CodingKey {
        case family, kind, value, operand2, display
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        family = try container.decode(String.self, forKey: .family)
        // `decodeIfPresent` covers an ABSENT key; `TagConditionKind`'s own
        // decoder covers an UNKNOWN value.
        kind = try container.decodeIfPresent(TagConditionKind.self, forKey: .kind) ?? .exact
        value = try container.decode(String.self, forKey: .value)
        operand2 = try container.decodeIfPresent(String.self, forKey: .operand2)
        display = try container.decode(String.self, forKey: .display)
    }
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

/// One rule's conditions, replaced in place.
///
/// The point of this payload is what it does NOT carry. The rule keeps its id,
/// its `createdAt` — when the finding was first recorded — and the origin
/// columns saying where it was first observed. Editing conditions changes none
/// of those, and the delete-then-add it replaces used to reset all four.
///
/// No `tagId`: the rule id is a primary key, and the core finds the tag by
/// subquery when it bumps `updatedAt`.
struct UpdateTagRule: Codable, Equatable {
    var ruleId: String
    var conditions: [TagCondition]
    /// `RuleKey.encode` is the only producer. Rust never builds one.
    var tupleKey: String
}
