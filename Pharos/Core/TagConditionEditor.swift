import Foundation

// MARK: - TagConditionEditor

/// What the manager offers for one condition, and whether what the analyst
/// typed is well formed.
///
/// The operator is a POPUP, not syntax. There is no grammar to get wrong and no
/// ambiguity between a comparator and a literal `>`; the hint under the value
/// field is where "how do I wildcard" is answered. That is why this type exists
/// rather than a parser.
///
/// Pure Foundation, so its harness compiles it on its own.
enum TagConditionEditor {

    /// The operators a family offers, in picker order.
    ///
    /// `exact` leads every list: it is the common case and the one an analyst
    /// reaches for without thinking. The rest follow the family's own rules —
    /// see `TagPredicate.compile`, which is the authority this list must agree
    /// with. The suite proves the agreement by compiling a probe for every pair
    /// rather than trusting two lists to stay in step.
    static func operators(for family: String) -> [TagConditionKind] {
        switch family {
        case TagValueNormalizer.textFamily:
            return [.exact, .glob]
        case TagValueNormalizer.addressFamily:
            return [.exact, .cidr]
        case TagValueNormalizer.numericFamily, TagValueNormalizer.temporalFamily:
            return [.exact, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between]
        default:
            // `uuid`, and every `type:<name>` family, compare as exact text.
            // Offering more would be offering something the matcher refuses.
            return [.exact]
        }
    }

    /// Does this operator take an upper bound as well?
    ///
    /// Only `between`, and it must be ONE condition rather than two
    /// comparators: conditions in a rule are ANDed, but each is satisfied by
    /// SOME cell in the row, not the same cell, so `>= 1000` and `<= 2000` as
    /// two conditions could be satisfied by two different columns and would not
    /// be a range test at all.
    static func needsSecondOperand(_ kind: TagConditionKind) -> Bool {
        kind == .between
    }

    /// The line under the value field, or "" when the operator explains itself.
    ///
    /// Empty rather than a filler sentence: a hint that appears on every
    /// operator is one the reader learns to skip, and then the three that
    /// matter go unread.
    static func hint(for kind: TagConditionKind) -> String {
        switch kind {
        case .glob:
            return "Use * for any text and ? for one character. Write \\* for a literal star."
        case .cidr:
            return "A CIDR block such as 107.8.8.0/24. Matches every address inside it."
        case .between:
            return "Inclusive at both ends."
        case .exact, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .unsupported:
            return ""
        }
    }

    // MARK: Probes, for the suite

    /// A value that is valid for this family and operator. Used ONLY by the
    /// suite, to prove `operators(for:)` never offers something
    /// `TagPredicate.compile` refuses.
    ///
    /// It lives here rather than in the test file because the two lists it
    /// bridges live here: a new operator added above without a probe fails to
    /// compile, which is the reminder.
    ///
    /// The temporal probes carry a trailing `Z`. `TagPredicate.compile` calls
    /// `TagValueNormalizer.comparableTimestamp` directly on `condition.value`,
    /// and that function requires its input to ALREADY be in canonical form —
    /// it checks `canonicalTimestamp(normalized) == normalized`, and the
    /// canonical form always ends in `Z`. A bare `"2026-08-13T00:00:00"` is not
    /// its own canonical form (canonicalizing it APPENDS the `Z`), so it fails
    /// that equality check and `compile` correctly refuses it — verified by
    /// running the suite with an un-suffixed probe before adding this comment.
    static func probeValue(for kind: TagConditionKind, family: String) -> String {
        switch kind {
        case .glob: return "a*"
        case .cidr: return "10.0.0.0/8"
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between:
            return family == TagValueNormalizer.temporalFamily ? "2026-08-13T00:00:00Z" : "1"
        case .exact, .unsupported: return "x"
        }
    }

    /// The upper bound for a probe, or nil where the operator takes none.
    static func probeOperand2(for kind: TagConditionKind, family: String) -> String? {
        guard needsSecondOperand(kind) else { return nil }
        return family == TagValueNormalizer.temporalFamily ? "2026-08-14T00:00:00Z" : "2"
    }
}
