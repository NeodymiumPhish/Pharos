import Foundation

// MARK: - TagPredicate

/// A condition that has been COMPILED, ready to test cells with.
///
/// Exact conditions never become predicates: they live in the matcher's hash
/// index, which answers them in O(1). This type is the second, linear path
/// `CIDRRange` predicted — the one a hash cannot provide, because a hash cannot
/// answer "does this cell fit this pattern".
///
/// Compiling happens ONCE per condition when the index is built, never per
/// cell: a glob is tokenized once, a CIDR parsed once, a comparator's operand
/// turned into a `Decimal` or a padded timestamp once. `matches` then parses
/// nothing.
///
/// `compile` returns nil for anything this build cannot evaluate — an unknown
/// kind, a kind its family cannot answer, an unparseable operand. The caller
/// skips the WHOLE RULE when any of its conditions fails to compile: a rule
/// missing one condition is EASIER to satisfy than the analyst wrote, and a
/// too-easy rule is a false match.
struct TagPredicate: Equatable {

    enum Test: Equatable {
        case glob([TagGlob.Token])
        case cidr(CIDRRange)
        /// The operand as a `Decimal`, plus an upper bound for `between`.
        case numeric(TagConditionKind, Decimal, Decimal?)
        /// The operand as a comparable string, plus an upper bound.
        case temporal(TagConditionKind, String, String?)
    }

    let test: Test

    // MARK: Compiling

    /// Compile `condition`, or nil when this build cannot evaluate it.
    ///
    /// `condition.value` and `condition.operand2` are already NORMALIZED by the
    /// same `TagValueNormalizer` rules their family uses — otherwise a glob
    /// would never match a lowercased cell, and a comparator would compare a raw
    /// operand against a canonical one.
    static func compile(_ condition: TagCondition) -> TagPredicate? {
        switch condition.kind {
        case .exact, .unsupported:
            // An exact condition belongs in the hash index; an unsupported one
            // cannot be evaluated at all. Neither is a predicate.
            return nil

        case .glob:
            guard condition.family == TagValueNormalizer.textFamily,
                  let tokens = TagGlob.compile(condition.value)
            else { return nil }
            return TagPredicate(test: .glob(tokens))

        case .cidr:
            guard condition.family == TagValueNormalizer.addressFamily,
                  let range = CIDRRange.parse(condition.value)
            else { return nil }
            return TagPredicate(test: .cidr(range))

        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between:
            let needsUpper = condition.kind == .between
            switch condition.family {
            case TagValueNormalizer.numericFamily:
                guard let lower = TagValueNormalizer.decimal(from: condition.value) else { return nil }
                let upper = condition.operand2.flatMap { TagValueNormalizer.decimal(from: $0) }
                guard !needsUpper || upper != nil else { return nil }
                return TagPredicate(test: .numeric(condition.kind, lower, upper))
            case TagValueNormalizer.temporalFamily:
                guard let lower = TagValueNormalizer.comparableTimestamp(condition.value)
                else { return nil }
                let upper = condition.operand2.flatMap { TagValueNormalizer.comparableTimestamp($0) }
                guard !needsUpper || upper != nil else { return nil }
                return TagPredicate(test: .temporal(condition.kind, lower, upper))
            default:
                return nil
            }
        }
    }

    // MARK: Matching

    /// Should this predicate be offered a cell of `family` at all?
    ///
    /// The matcher asks once per family per result, so an irrelevant column
    /// costs nothing — the same saving the exact path already makes with its
    /// own family set.
    ///
    /// A `cidr` predicate answers the TEXT family as well as the address one.
    /// Analysts store addresses in `text` columns constantly, and an
    /// address-family-only condition would miss every CSV-imported log table.
    /// It is safe here and not for comparators because `inet_pton` is a STRONG
    /// filter: text that is not an address fails to parse and never matches.
    /// Numeric parsing is a weak filter — plenty of prose is digits — and there
    /// is no column scoping to contain the noise, so comparators deliberately
    /// do not follow.
    func tests(family: String) -> Bool {
        switch test {
        case .glob:
            return family == TagValueNormalizer.textFamily
        case .cidr:
            return family == TagValueNormalizer.addressFamily
                || family == TagValueNormalizer.textFamily
        case .numeric:
            return family == TagValueNormalizer.numericFamily
        case .temporal:
            return family == TagValueNormalizer.temporalFamily
        }
    }

    /// Does one NORMALIZED cell value satisfy this predicate?
    ///
    /// A value that FELL BACK to raw text never matches a comparator.
    /// `TagValueNormalizer` keeps unparseable text as-is, so `decimal(from:)`
    /// and `comparableTimestamp` answer nil for exactly those values, and nil
    /// means no match rather than a byte compare. A byte compare there is the
    /// false match the normalizer's own gates exist to prevent: tag a
    /// `-infinity` float8 and every literal zero in that column would match it.
    func matches(normalized: String, family: String) -> Bool {
        switch test {
        case .glob(let tokens):
            return TagGlob.matches(tokens, normalized)

        case .cidr(let range):
            guard let candidate = CIDRRange.parse(normalized) else { return false }
            return range.contains(candidate)

        case .numeric(let kind, let lower, let upper):
            guard let value = TagValueNormalizer.decimal(from: normalized) else { return false }
            return Self.ordered(kind, value, lower, upper)

        case .temporal(let kind, let lower, let upper):
            guard let value = TagValueNormalizer.comparableTimestamp(normalized) else { return false }
            return Self.ordered(kind, value, lower, upper)
        }
    }

    /// The one comparison, over any `Comparable`. Written once so the numeric
    /// and temporal branches cannot disagree about whether a bound is inclusive.
    private static func ordered<T: Comparable>(
        _ kind: TagConditionKind, _ value: T, _ lower: T, _ upper: T?
    ) -> Bool {
        switch kind {
        case .greaterThan: return value > lower
        case .greaterOrEqual: return value >= lower
        case .lessThan: return value < lower
        case .lessOrEqual: return value <= lower
        case .between:
            // `compile` refuses a `between` with no upper bound, so this is
            // unreachable — but false is the safe answer if it ever is reached,
            // because a missing bound must never WIDEN a rule.
            guard let upper else { return false }
            return value >= lower && value <= upper
        default:
            return false
        }
    }
}
