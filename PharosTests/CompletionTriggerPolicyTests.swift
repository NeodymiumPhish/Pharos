// Standalone test runner for the two PURE completion decisions:
// `CompletionTriggerPolicy` (does the list open here?) and `KeywordCasing`
// (what case does an inserted keyword take?). Not part of the app target —
// compiled together with the implementation by
// scripts/test-completion-trigger-policy.sh.
//
// Both are pure functions with no AppKit and no settings store in them, so
// every rule the Settings ▸ Editor ▸ Completion section promises can be
// checked here rather than by driving a text view.
import Foundation

var failures = 0

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    expect(actual == expected, name, "got \(actual), expected \(expected)")
}

/// Shorthand: everything the policy needs, with the settings that are not
/// under test held at their defaults.
func offers(
    _ trigger: CompletionTrigger,
    prefix: String = "",
    preceding: Character? = nil,
    minimum: Int = 1,
    inStringOrComment: Bool = false
) -> Bool {
    CompletionTriggerPolicy.shouldOffer(
        trigger: trigger,
        minimumCharacters: minimum,
        prefix: prefix,
        precedingCharacter: preceding,
        isInStringOrComment: inStringOrComment)
}

func runTests() {
    // ---- off never offers ----
    expect(!offers(.off), "off: an empty prefix does not offer")
    expect(!offers(.off, preceding: "."), "off: a dot does not offer")
    expect(!offers(.off, prefix: "customer", preceding: "r"),
           "off: a long identifier does not offer")

    // ---- afterDot offers only right after a dot ----
    expect(offers(.afterDot, preceding: "."), "afterDot: a dot offers")
    expect(!offers(.afterDot, prefix: "cust", preceding: "t"),
           "afterDot: an identifier does not offer")
    expect(!offers(.afterDot, preceding: " "), "afterDot: a space does not offer")
    expect(!offers(.afterDot), "afterDot: the start of the document does not offer")
    expect(offers(.afterDot, prefix: "name", preceding: "."),
           "afterDot: a dot offers even with a prefix already typed")

    // ---- afterDotAndIdentifiers: the dot still offers ----
    expect(offers(.afterDotAndIdentifiers, preceding: "."),
           "afterDotAndIdentifiers: a dot offers")

    // ---- afterDotAndIdentifiers: at or above the minimum ----
    expect(offers(.afterDotAndIdentifiers, prefix: "c", preceding: "c", minimum: 1),
           "minimum 1: one character offers")
    expect(offers(.afterDotAndIdentifiers, prefix: "cu", preceding: "u", minimum: 2),
           "minimum 2: exactly two characters offers (at the minimum)")
    expect(offers(.afterDotAndIdentifiers, prefix: "cust", preceding: "t", minimum: 2),
           "minimum 2: four characters offers (above the minimum)")

    // ---- a prefix shorter than the minimum does not offer ----
    expect(!offers(.afterDotAndIdentifiers, prefix: "c", preceding: "c", minimum: 2),
           "minimum 2: one character does not offer")
    expect(!offers(.afterDotAndIdentifiers, prefix: "cust", preceding: "t", minimum: 5),
           "minimum 5: four characters does not offer")
    expect(!offers(.afterDotAndIdentifiers, prefix: "", preceding: " ", minimum: 1),
           "an empty prefix after a space does not offer")

    // A minimum below 1 is held at 1, so an empty prefix still cannot open
    // the list on every keystroke.
    expect(!offers(.afterDotAndIdentifiers, prefix: "", preceding: " ", minimum: 0),
           "minimum 0 is held at 1: an empty prefix does not offer")

    // ---- never inside a string or a comment ----
    for trigger in CompletionTrigger.allCases {
        expect(!offers(trigger, prefix: "cust", preceding: ".", inStringOrComment: true),
               "\(trigger.rawValue): a dot inside a string or comment does not offer")
        expect(!offers(trigger, prefix: "customer", preceding: "r", minimum: 1,
                       inStringOrComment: true),
               "\(trigger.rawValue): an identifier inside a string or comment does not offer")
    }

    // ---- KeywordCasing ----
    expectEqual(KeywordCasing.applied("SELECT", case: .upper, typed: "sel"), "SELECT",
                "upper: an uppercase keyword stays uppercase")
    expectEqual(KeywordCasing.applied("select", case: .upper, typed: "sel"), "SELECT",
                "upper: a lowercase keyword is raised")
    expectEqual(KeywordCasing.applied("SELECT", case: .lower, typed: "SEL"), "select",
                "lower: an uppercase keyword is lowered")
    expectEqual(KeywordCasing.applied("select", case: .lower, typed: "SEL"), "select",
                "lower: a lowercase keyword stays lowercase")

    expectEqual(KeywordCasing.applied("SELECT", case: .matchTyping, typed: "SEL"), "SELECT",
                "matchTyping: all-caps typed gives upper")
    expectEqual(KeywordCasing.applied("SELECT", case: .matchTyping, typed: "sel"), "select",
                "matchTyping: lowercase typed gives lower")
    expectEqual(KeywordCasing.applied("SELECT", case: .matchTyping, typed: "Sel"), "SELECT",
                "matchTyping: mixed typed gives the keyword's canonical form")
    expectEqual(KeywordCasing.applied("select", case: .matchTyping, typed: "Sel"), "select",
                "matchTyping: mixed typed keeps a lowercase keyword as it is")
    expectEqual(KeywordCasing.applied("SELECT", case: .matchTyping, typed: ""), "SELECT",
                "matchTyping: nothing typed keeps the canonical form")
    expectEqual(KeywordCasing.applied("SELECT", case: .matchTyping, typed: "_"), "SELECT",
                "matchTyping: a prefix with no letters keeps the canonical form")
    expectEqual(KeywordCasing.applied("SELECT", case: .matchTyping, typed: "s1"), "select",
                "matchTyping: digits are ignored, the letter decides")
    expectEqual(KeywordCasing.applied("ORDER BY", case: .matchTyping, typed: "OR"), "ORDER BY",
                "matchTyping: a two-word keyword is raised as one")

    // ---- the two enums agree with the stored spellings ----
    expectEqual(CompletionTrigger.allCases.map(\.rawValue),
                ["off", "afterDot", "afterDotAndIdentifiers"],
                "CompletionTrigger's stored spellings match the Rust mirror")
    expectEqual(KeywordCase.allCases.map(\.rawValue), ["upper", "lower", "matchTyping"],
                "KeywordCase's stored spellings match the Rust mirror")
    expectEqual(CompletionTrigger(), CompletionTrigger.afterDot,
                "CompletionTrigger's settings default is today's behaviour")
    expectEqual(KeywordCase(), KeywordCase.upper,
                "KeywordCase's settings default is today's behaviour")

    if failures > 0 {
        print("\n\(failures) FAILED")
        exit(1)
    }
    print("\nALL PASSED")
}

/// The defaults these two enums carry in `EditorSettings`, so the test above
/// can name them without reaching into the whole settings struct.
extension CompletionTrigger {
    init() { self = EditorSettings().completionTrigger }
}

extension KeywordCase {
    init() { self = EditorSettings().completionKeywordCase }
}
