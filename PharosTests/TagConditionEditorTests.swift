// Standalone test for TagConditionEditor: which operators a family offers, the
// hint under the value field, and whether a second operand is needed.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    // MARK: operators per family

    // Every family offers `exact` FIRST. It is the common case and the one an
    // analyst reaches for without thinking.
    for family in ["text", "address", "numeric", "temporal", "uuid", "type:bool"] {
        expect(TagConditionEditor.operators(for: family).first == .exact,
               "\(family) leads with exact")
    }

    expect(TagConditionEditor.operators(for: "text") == [.exact, .glob],
           "text offers exact and glob")
    expect(TagConditionEditor.operators(for: "address") == [.exact, .cidr],
           "address offers exact and cidr")
    expect(TagConditionEditor.operators(for: "numeric")
            == [.exact, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between],
           "numeric offers the comparators")
    expect(TagConditionEditor.operators(for: "temporal")
            == [.exact, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .between],
           "temporal offers the same comparators")

    // A family with no rule of its own can only be matched exactly.
    expect(TagConditionEditor.operators(for: "uuid") == [.exact], "uuid offers only exact")
    expect(TagConditionEditor.operators(for: "type:bool") == [.exact],
           "an exotic family offers only exact")
    expect(TagConditionEditor.operators(for: "type:int4[]") == [.exact],
           "an array type offers only exact")

    // MARK: the operators agree with what the matcher can actually compile

    // This is the property that matters: the picker must never offer an
    // operator TagPredicate would refuse. Proved against the real compiler
    // rather than a second list.
    for family in ["text", "address", "numeric", "temporal", "uuid", "type:bool"] {
        for kind in TagConditionEditor.operators(for: family) where kind != .exact {
            let probe = TagCondition(family: family, kind: kind,
                                     value: TagConditionEditor.probeValue(for: kind, family: family),
                                     operand2: TagConditionEditor.probeOperand2(for: kind, family: family),
                                     display: "probe")
            expect(TagPredicate.compile(probe) != nil,
                   "\(family)/\(kind.rawValue) is compilable by the matcher")
        }
    }

    // MARK: second operand

    expect(TagConditionEditor.needsSecondOperand(.between), "between needs a second operand")
    for kind in [TagConditionKind.exact, .glob, .cidr, .greaterThan, .greaterOrEqual,
                 .lessThan, .lessOrEqual] {
        expect(!TagConditionEditor.needsSecondOperand(kind),
               "\(kind.rawValue) needs no second operand")
    }

    // MARK: hints

    // The hint is where "how do I wildcard" is answered, so glob, cidr and
    // between must each say something concrete.
    expect(TagConditionEditor.hint(for: .glob).contains("*"),
           "the glob hint shows the star")
    expect(TagConditionEditor.hint(for: .glob).contains("?"),
           "the glob hint shows the question mark")
    expect(TagConditionEditor.hint(for: .cidr).contains("/"),
           "the cidr hint shows a prefix length")
    expect(!TagConditionEditor.hint(for: .between).isEmpty,
           "between has a hint")

    // An operator that needs no explanation has no hint, rather than a filler
    // sentence the reader learns to skip.
    expect(TagConditionEditor.hint(for: .exact).isEmpty, "exact needs no hint")

    // An unknown kind never crashes and never invents guidance.
    expect(TagConditionEditor.hint(for: .unsupported("startsWith")).isEmpty,
           "an unsupported kind has no hint")
    expect(TagConditionEditor.operators(for: "text").allSatisfy { $0.isSupported },
           "the picker never offers an unsupported kind")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
