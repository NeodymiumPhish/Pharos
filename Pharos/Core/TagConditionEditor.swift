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

    /// The words for an operator in a picker, which differ by family: `>` on a
    /// number reads as `after` on a date.
    ///
    /// Not `rawValue` — that is the wire string. A picker showing
    /// `greaterOrEqual` would be the model leaking into the interface.
    static func label(for kind: TagConditionKind, family: String) -> String {
        let temporal = family == TagValueNormalizer.temporalFamily
        switch kind {
        case .exact: return "is"
        case .glob: return "matches"
        case .cidr: return "in range"
        case .greaterThan: return temporal ? "after" : ">"
        case .greaterOrEqual: return temporal ? "on or after" : "≥"
        case .lessThan: return temporal ? "before" : "<"
        case .lessOrEqual: return temporal ? "on or before" : "≤"
        case .between: return "between"
        // A kind from a newer build has no words of ours. Its own raw value is
        // the only honest label, escaped because it is stored text.
        case .unsupported(let raw): return DisplayEscape.escaped(raw)
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

    // MARK: Validation

    /// Why a typed condition is not well formed.
    ///
    /// `Error` as well as `Equatable`: `Result<TagCondition, Invalid>` requires
    /// its failure type to conform to `Error`, which the handed-over spec
    /// omitted.
    enum Invalid: Equatable, Error {
        case emptyValue
        case emptySecondOperand
        /// The matcher refused it. The string is ready to draw beside the field.
        case unparseable(String)
        /// The family cannot host this operator at all — a `cidr` against text,
        /// or a comparator against text. The message names the disagreement
        /// rather than blaming the typed value, which is well formed.
        case wrongOperator(String)
    }

    /// Turn what the analyst typed into a condition, or say what is wrong.
    ///
    /// The typed text survives into `display` BYTE FOR BYTE. A condition value
    /// is TIER 1 — never altered — because it DESCRIBES hostile data: an analyst
    /// hunting Trojan Source or IDN homograph abuse must be able to name a
    /// hostname that genuinely carries a bidi override. Sanitising the field
    /// would silently destroy the hunt this feature exists for. `value` is a
    /// normalized form derived BESIDE the typed text, never in place of it.
    ///
    /// The refusal delegates to `TagPredicate.compile`. A second copy of the
    /// rules could accept something the matcher then refuses, and a condition
    /// that saves but never matches is the worst outcome available here: the tag
    /// looks like it is watching something when it is not.
    static func condition(family: String, kind: TagConditionKind,
                          value: String, operand2: String) -> Result<TagCondition, Invalid> {
        // Trim only for the EMPTINESS test. What is stored in `display` is
        // untouched, and normalization does its own trimming per family.
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyValue)
        }
        let wantsUpper = needsSecondOperand(kind)
        if wantsUpper, operand2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.emptySecondOperand)
        }

        let built = TagCondition(
            family: family,
            kind: kind,
            value: TagValueNormalizer.normalize(value, family: family),
            // An operand the operator does not take is DROPPED rather than
            // stored: the popup can change under a field that still holds text,
            // and a stray bound would sit in the rule key and split one finding
            // into two.
            operand2: wantsUpper ? TagValueNormalizer.normalize(operand2, family: family) : nil,
            display: value)

        // An exact condition never reaches the compiler — it lives in the hash
        // index, and `compile` returns nil for it by design.
        guard kind != .exact else { return .success(built) }

        // An unsupported kind first: it has a better message of its own, and it
        // appears in no family's operator list, so the agreement check below
        // would otherwise swallow it.
        guard kind.isSupported else {
            return .failure(.unparseable(refusal(kind: kind, family: family)))
        }

        // Then the family/operator agreement. `compile` answers only yes or no,
        // so without this the refusal would blame a well-formed value for a
        // disagreement it had no part in. `operators(for:)` is the authority,
        // which also ties this function to the picker: they can never disagree
        // about what is offerable.
        guard operators(for: family).contains(kind) else {
            return .failure(.wrongOperator(
                "A \(TagFamilyLabel.text(for: family)) condition cannot use this operator."))
        }

        guard TagPredicate.compile(built) != nil else {
            return .failure(.unparseable(refusal(kind: kind, family: family)))
        }
        return .success(built)
    }

    /// The message shown beside a refused field.
    ///
    /// Written per operator, because "invalid" tells an analyst nothing they can
    /// act on. `TagPredicate.compile` answers only yes or no, so the reason is
    /// reconstructed from what that operator requires — safe because each
    /// operator has exactly one way to fail its parse.
    private static func refusal(kind: TagConditionKind, family: String) -> String {
        switch kind {
        case .cidr:
            return "Not an address or CIDR block. Try 107.8.8.0/24."
        case .glob:
            return "Not a usable pattern. A lone \\ at the end has nothing to escape."
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between:
            return family == TagValueNormalizer.temporalFamily
                ? "Not a date or time this can compare. Try 2026-08-13 or 2026-08-13 12:34:56."
                : "Not a number this can compare."
        case .exact:
            // Unreachable: an exact condition returns before the compile gate.
            return "Not usable here."
        case .unsupported(let raw):
            // Reached through the `kind.isSupported` guard in `condition`,
            // which routes an unsupported kind here before the family/operator
            // agreement check can swallow it with a less useful message. That
            // guard's only caller today hands back a kind read from storage —
            // the picker never offers one — but this message is live, not dead.
            return "This build does not understand the operator \(DisplayEscape.escaped(raw))."
        }
    }
}
