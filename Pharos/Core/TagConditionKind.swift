import Foundation

// MARK: - TagConditionKind

/// What a condition TESTS, rather than what it holds.
///
/// Deliberately NOT a `String`-backed `RawRepresentable` `Codable` enum. That
/// spelling THROWS on an unknown raw value, and one condition written by a
/// newer build would then fail the decode of the entire tag list.
///
/// The Rust side has a worse version of the same trap. `read_tag_tuples`
/// (`pharos-core/src/db/sqlite.rs`) decodes the stored `tuple_values` blob with
/// `unwrap_or_default()`, assuming the only failure is corrupt JSON. An enum
/// that rejects an unknown variant makes the WHOLE blob fail, so the rule loads
/// with an EMPTY condition list — inert in the matcher, and written back empty
/// by the next save. That destroys the rule silently, with no error anywhere.
///
/// So an unknown value is KEPT, verbatim, as `.unsupported`. It re-encodes byte
/// for byte, which is what lets a rule this build cannot evaluate survive a
/// round trip through it. The matcher skips such a rule whole, and the manager
/// shows it read-only.
///
/// `#[serde(default)]` and `decodeIfPresent` protect against an ABSENT field.
/// Neither protects against an unknown VALUE. This type is the part that does.
enum TagConditionKind: Hashable {
    case exact
    case glob
    case cidr
    case greaterThan
    case greaterOrEqual
    case lessThan
    case lessOrEqual
    case between
    /// An unknown kind, kept exactly as it arrived.
    case unsupported(String)

    /// Every kind this build can evaluate, in the order a picker shows them.
    static let known: [TagConditionKind] = [
        .exact, .glob, .cidr, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between,
    ]

    var rawValue: String {
        switch self {
        case .exact: return "exact"
        case .glob: return "glob"
        case .cidr: return "cidr"
        case .greaterThan: return "greaterThan"
        case .greaterOrEqual: return "greaterOrEqual"
        case .lessThan: return "lessThan"
        case .lessOrEqual: return "lessOrEqual"
        case .between: return "between"
        case .unsupported(let raw): return raw
        }
    }

    init(rawValue: String) {
        self = Self.known.first { $0.rawValue == rawValue } ?? .unsupported(rawValue)
    }

    /// Can this build evaluate it? A rule holding one that cannot is skipped
    /// whole, never partly — a rule missing one condition would be EASIER to
    /// satisfy than the analyst wrote, and a too-easy rule is a false match.
    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

extension TagConditionKind: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
