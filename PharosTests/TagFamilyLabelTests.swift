// Standalone test for TagFamilyLabel. Compiled with
// Pharos/Core/TagFamilyLabel.swift only (pure Foundation).
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    expect(TagFamilyLabel.text(for: "text") == "Text", "text family")
    expect(TagFamilyLabel.text(for: "address") == "Address", "address family")
    expect(TagFamilyLabel.text(for: "numeric") == "Number", "numeric family")
    expect(TagFamilyLabel.text(for: "temporal") == "Date & time", "temporal family")
    expect(TagFamilyLabel.text(for: "uuid") == "UUID", "uuid family")

    // The ORDER is deliberate — a later type picker shows these in it — so it
    // is pinned. A comment alone would not survive a reorder.
    expect(TagFamilyLabel.known.map(\.family) == ["text", "address", "numeric", "temporal", "uuid"],
           "the known family order is fixed")

    // An exotic type keeps its own name as its family. The label shows the
    // TYPE, not the "type:" bookkeeping prefix the normalizer added.
    expect(TagFamilyLabel.text(for: "type:bool") == "bool", "type: prefix stripped")
    expect(TagFamilyLabel.text(for: "type:int4[]") == "int4[]", "array type keeps brackets")

    // A family this code has never seen is shown verbatim rather than dropped:
    // a blank label on a delete confirmation is the worst possible disclosure.
    expect(TagFamilyLabel.text(for: "future") == "future", "unknown family shown verbatim")

    // A family is a STORED string and can in principle be anything. It is
    // escaped like every other stored text this app draws. The PROPERTY is
    // asserted, not the spelling: DisplayEscape owns the token format and this
    // suite must not pin it a second time.
    expect(!TagFamilyLabel.text(for: "type:a\u{202E}b").unicodeScalars.contains("\u{202E}"),
           "a hostile family scalar is escaped, never drawn raw")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
