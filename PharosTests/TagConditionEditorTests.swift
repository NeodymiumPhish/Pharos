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

    // MARK: validation

    func build(_ family: String, _ kind: TagConditionKind, _ value: String,
               _ operand2: String = "") -> Result<TagCondition, TagConditionEditor.Invalid> {
        TagConditionEditor.condition(family: family, kind: kind, value: value, operand2: operand2)
    }

    func built(_ family: String, _ kind: TagConditionKind, _ value: String,
               _ operand2: String = "") -> TagCondition? {
        try? build(family, kind, value, operand2).get()
    }

    func rejection(_ family: String, _ kind: TagConditionKind, _ value: String,
                   _ operand2: String = "") -> TagConditionEditor.Invalid? {
        switch build(family, kind, value, operand2) {
        case .success: return nil
        case .failure(let why): return why
        }
    }

    // The happy path stores the NORMALIZED form for matching and the RAW text
    // for display, byte for byte.
    let exact = built("text", .exact, "  EVIL.com  ")
    expect(exact?.value == "evil.com", "an exact condition stores the normalized value")
    expect(exact?.display == "  EVIL.com  ", "and the raw text as typed, byte for byte")
    expect(exact?.kind == .exact, "and its kind")

    // A condition value is TIER 1 — never altered. An invisible character is
    // kept, because an analyst hunting Trojan Source or IDN homograph abuse must
    // be able to describe hostile data exactly as it appears.
    let hostile = built("text", .exact, "ev\u{202E}il.com")
    expect(hostile?.display.unicodeScalars.contains("\u{202E}") == true,
           "a bidi override survives into display, unaltered")

    // Emptiness is refused before anything else.
    expect(rejection("text", .exact, "") == .emptyValue, "an empty value is refused")
    expect(rejection("text", .exact, "   ") == .emptyValue, "whitespace alone is refused")
    expect(rejection("numeric", .between, "1", "") == .emptySecondOperand,
           "between with no upper bound is refused")

    // A second operand supplied where none is taken is ignored, not an error —
    // the popup can change under a field that still holds text.
    expect(built("text", .exact, "a", "leftover")?.operand2 == nil,
           "an unused second operand is dropped")

    // Anything TagPredicate would refuse is refused HERE, with the reason to
    // show inline. Delegating rather than re-deriving is what keeps the editor
    // from accepting a condition that saves but never matches.
    expect(rejection("address", .cidr, "10.2.3.999") != nil, "a malformed CIDR is refused")
    expect(rejection("numeric", .greaterThan, "-Infinity") != nil,
           "a non-numeric comparator operand is refused")
    expect(rejection("numeric", .between, "1", "not a number") != nil,
           "an unparseable upper bound is refused")
    expect(rejection("temporal", .greaterThan, "3 days") != nil,
           "an unparseable temporal operand is refused")
    expect(rejection("text", .glob, #"abc\"#) != nil,
           "a glob ending in a lone backslash is refused")

    // Every rejection carries text a human can act on.
    if case .unparseable(let message)? = rejection("address", .cidr, "10.2.3.999") {
        expect(!message.isEmpty, "a rejection carries a message")
        expect(!message.contains("nil"), "and it is not a raw Swift value")
    } else {
        expect(false, "a malformed CIDR is rejected as unparseable")
    }

    // A valid pattern condition round-trips through the matcher.
    let glob = built("text", .glob, "*.neodymiumphi.sh")
    expect(glob != nil && TagPredicate.compile(glob!) != nil,
           "a validated glob compiles for the matcher")
    let between = built("numeric", .between, "1000", "2000")
    expect(between?.operand2 == "2000", "between keeps its upper bound normalized")
    expect(between != nil && TagPredicate.compile(between!) != nil,
           "a validated between compiles for the matcher")

    // A valid TEMPORAL comparator round-trips too. Task 1 found that
    // TagPredicate.compile reads the raw value through comparableTimestamp,
    // which only accepts its own canonical form — so this is the case that
    // proves `condition` normalizes before compiling, rather than after.
    let after = built("temporal", .greaterThan, "2026-08-13 12:34:56")
    expect(after != nil, "a plain timestamp is accepted")
    expect(after != nil && TagPredicate.compile(after!) != nil,
           "and it compiles for the matcher")

    // An unsupported kind can never be AUTHORED — it only ever arrives from
    // storage written by a newer build.
    expect(rejection("text", .unsupported("startsWith"), "a") != nil,
           "an unsupported kind cannot be authored")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
