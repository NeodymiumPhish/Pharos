import Foundation

/// "Test a value": which of a tag's rules a typed sample value satisfies,
/// before any results exist.
///
/// A sample is tested in each condition's OWN type: the question answered is
/// "would a cell holding this value, in a column of the rule's type, match?",
/// because the user typing a sample does not know a column type. The matcher's
/// pieces do the work — `TagValueNormalizer` for an exact condition,
/// `TagPredicate` for a pattern, a range or a comparison — so the answer is the
/// grid's. A rule matches when the one value satisfies all of its conditions;
/// a rule with several conditions usually needs several cells, so it reports
/// how many the value satisfies. Pure (`scripts/test-tag-sample-test.sh`).
enum TagSampleTest {
    struct RuleResult: Equatable {
        /// 1-based, as the grid titles rules ("Rule 2").
        let ordinal: Int
        let matched: Int
        let total: Int
        var isMatch: Bool { total > 0 && matched == total }
    }

    static func conditionMatches(_ condition: TagCondition, sample: String) -> Bool {
        let family = condition.family
        let normalized = TagValueNormalizer.normalize(sample, family: family)
        switch condition.kind {
        case .exact:
            return normalized == condition.value
        case .unsupported:
            return false
        default:
            guard let predicate = TagPredicate.compile(condition), predicate.tests(family: family) else { return false }
            return predicate.matches(normalized: normalized, family: family)
        }
    }

    /// `rules`: each rule's conditions, in the grid's order.
    static func evaluate(_ sample: String, rules: [[TagCondition]]) -> [RuleResult] {
        rules.enumerated().map { index, conditions in
            RuleResult(ordinal: index + 1,
                       matched: conditions.filter { conditionMatches($0, sample: sample) }.count,
                       total: conditions.count)
        }
    }

    /// "Matches rule 1 and rule 3. Rule 2: 1 of 2 conditions." — or "No rule
    /// matches this value."; empty for an empty sample.
    static func summary(_ results: [RuleResult], sample: String) -> String {
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let whole = results.filter(\.isMatch).map { String(localized: "rule \($0.ordinal)") }
        let partial = results.filter { !$0.isMatch && $0.matched > 0 }
        var parts: [String] = []
        if !whole.isEmpty {
            parts.append(String(localized: "Matches \(ListFormatter.localizedString(byJoining: whole)).",
                                comment: "Tag sample test: the rules the value matches."))
        }
        for result in partial {
            parts.append(String(localized: "Rule \(result.ordinal): \(result.matched) of \(result.total) conditions.",
                                comment: "Tag sample test: a rule the value only partly satisfies."))
        }
        return parts.isEmpty ? String(localized: "No rule matches this value.") : parts.joined(separator: " ")
    }
}
