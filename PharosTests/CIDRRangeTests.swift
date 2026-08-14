// Standalone runner for CIDRRange. Foundation + Darwin only.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // 1. A bare address canonicalises to itself.
    expectEqual(CIDRRange.canonical("10.2.3.4"), "10.2.3.4", "v4 bare address")

    // 2. A full-length prefix is dropped: /32 says nothing a bare address does
    //    not, and the design requires 10.2.3.4/32 to equal 10.2.3.4.
    expectEqual(CIDRRange.canonical("10.2.3.4/32"), "10.2.3.4", "v4 /32 drops the prefix")
    expectEqual(CIDRRange.canonical("2001:db8::1/128"), "2001:db8::1", "v6 /128 drops the prefix")

    // 3. A shorter prefix is kept — it is a different thing from a host.
    expectEqual(CIDRRange.canonical("10.2.3.0/24"), "10.2.3.0/24", "v4 /24 keeps the prefix")
    expectEqual(CIDRRange.canonical("10.2.3.0/0"), "10.2.3.0/0", "/0 is a legal prefix")

    // 4. IPv6 spelling collapses: case and zero-compression are representation,
    //    not identity.
    expectEqual(CIDRRange.canonical("2001:0DB8:0000:0000:0000:0000:0000:0001"),
                "2001:db8::1", "v6 expanded upper-case collapses")

    // 5. Junk never matches and never traps.
    expectEqual(CIDRRange.canonical("10.2.3.999"), nil, "out-of-range octet is nil")
    expectEqual(CIDRRange.canonical("not an address"), nil, "text is nil")
    expectEqual(CIDRRange.canonical(""), nil, "empty is nil")
    expectEqual(CIDRRange.canonical("10.2.3.4/33"), nil, "prefix past the family width is nil")
    expectEqual(CIDRRange.canonical("10.2.3.4/-1"), nil, "negative prefix is nil")
    expectEqual(CIDRRange.canonical("10.2.3.4/abc"), nil, "non-numeric prefix is nil")

    // 6. Whitespace around a value is not part of it.
    expectEqual(CIDRRange.canonical("  10.2.3.4  "), "10.2.3.4", "surrounding space is trimmed")

    // 7. The families do not blur into each other.
    let v4 = CIDRRange.parse("10.2.3.4")
    let v6 = CIDRRange.parse("::ffff:10.2.3.4")
    expectEqual(v4?.isIPv6, false, "dotted quad parses as v4")
    expectEqual(v6?.isIPv6, true, "v4-mapped v6 stays v6")
    expectEqual(v4 == v6, false, "a v4 address never equals a v6 one")

    print(failures == 0 ? "\nAll CIDRRange checks passed" : "\n\(failures) FAILED")
    if failures > 0 { exit(1) }
}
