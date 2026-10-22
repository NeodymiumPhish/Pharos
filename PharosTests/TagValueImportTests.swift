// Standalone test for TagValueImport — compiled by scripts/test-tag-value-import.sh.
import Foundation

private var failures = 0
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    let A = TagValueNormalizer.addressFamily, T = TagValueNormalizer.textFamily
    let N = TagValueNormalizer.numericFamily, D = TagValueNormalizer.temporalFamily, U = TagValueNormalizer.uuidFamily
    func kind(_ v: String) -> String { let d = TagValueImport.detect(v); return "\(d.family)/\(d.kind.rawValue)" }
    expect(kind("10.0.0.0/8"), "\(A)/cidr", "a CIDR range")
    expect(kind("2001:db8::/32"), "\(A)/cidr", "an IPv6 range")
    expect(kind("10.0.0.1"), "\(A)/exact", "an address")
    expect(kind("::1"), "\(A)/exact", "an IPv6 address")
    expect(kind("42"), "\(N)/exact", "a number")
    expect(kind("-3.5"), "\(N)/exact", "a negative decimal")
    expect(kind("2026-10-22"), "\(D)/exact", "a date")
    expect(kind("550e8400-e29b-41d4-a716-446655440000"), "\(U)/exact", "a UUID")
    expect(kind("*.example.com"), "\(T)/glob", "a wildcard pattern")
    expect(kind("evil.example.com"), "\(T)/exact", "plain text")
    expect(kind("5-"), "\(T)/exact", "not a number: text")

    let existing = [[TagCondition(family: A, kind: .exact, value: "10.0.0.9", display: "10.0.0.9")]]
    let pasted = "10.0.0.1\n\n  10.0.0.0/8  \n10.0.0.1\n10.0.0.9\nphish.example\n10.0.0.300/40\n"
    let lines = TagValueImport.lines(from: pasted, existing: existing)
    expect(lines.map(\.text), ["10.0.0.1", "10.0.0.0/8", "10.0.0.1", "10.0.0.9", "phish.example", "10.0.0.300/40"],
           "one line per value, blanks left out, each trimmed")
    expect(lines[0].status, .ready, "a new address is ready")
    expect(lines[1].status, .ready, "a range is ready")
    expect(lines[2].status, .repeated, "a repeated line is not added twice")
    expect(lines[3].status, .alreadyInTag, "a value the tag already has is not added again")
    expect(lines[4].status, .ready, "text is ready")
    expect(lines[1].typeLabel, "Address · in range", "the preview names the type")
    expect(TagValueImport.readyConditions(lines).map(\.display), ["10.0.0.1", "10.0.0.0/8", "phish.example"],
           "only the ready lines are added, in order")
    expect(lines[5].status, .invalid("Not a valid address or range."), "a malformed range is refused, not made text")
    expect(lines[5].typeLabel, "Address · in range", "and shown as the range it was meant to be")
    expect(TagValueImport.looksLikeAddress("10.0.0.300"), true, "an address-shaped typo")
    expect(TagValueImport.looksLikeAddress("1.5"), false, "a decimal is not an address")
    expect(TagValueImport.looksLikeAddress("example.com"), false, "a domain is not an address")
    expect(TagValueImport.looksLikeAddress("12:30"), true, "a clock time has the shape (it is refused, not guessed)")
    expect(TagValueImport.lines(from: "  \n\n", existing: []).count, 0, "only blank lines: nothing")

    if failures == 0 { print("\nAll tag value import tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
