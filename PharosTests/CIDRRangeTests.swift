// Standalone runner for CIDRRange. Foundation + Darwin only.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) { expectEqual(actual, true, name) }
func expectFalse(_ actual: Bool, _ name: String) { expectEqual(actual, false, name) }

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

    // MARK: containment

    func range(_ t: String) -> CIDRRange { CIDRRange.parse(t)! }

    expectTrue(range("10.2.3.0/24").contains(range("10.2.3.4")), "v4 host inside its /24")
    expectFalse(range("10.2.3.0/24").contains(range("10.2.4.4")), "v4 host outside its /24")

    // A prefix that is not byte-aligned is where a byte-wise compare goes
    // wrong, so it gets its own cases on both sides of the boundary.
    expectTrue(range("10.0.0.0/12").contains(range("10.15.255.255")), "last address of a /12")
    expectFalse(range("10.0.0.0/12").contains(range("10.16.0.0")), "first address past a /12")

    // `spare == 1` and `spare == 7` are the two ends of the shift. The `/12`
    // case above cannot see a swapped shift direction, because at `spare == 4`
    // both directions compute the same mask.
    expectTrue(range("10.0.0.0/17").contains(range("10.0.127.255")), "last address of a /17")
    expectFalse(range("10.0.0.0/17").contains(range("10.0.128.0")), "first address past a /17")
    expectTrue(range("10.0.0.0/15").contains(range("10.1.255.255")), "last address of a /15")
    expectFalse(range("10.0.0.0/15").contains(range("10.2.0.0")), "first address past a /15")

    // A range can only hold something at least as SPECIFIC as itself.
    expectTrue(range("10.0.0.0/8").contains(range("10.2.3.0/24")), "/8 holds a /24 inside it")
    expectFalse(range("10.2.3.0/24").contains(range("10.0.0.0/8")), "/24 does not hold its own /8")

    // Equal ranges contain each other; /0 holds everything of its family.
    expectTrue(range("10.2.3.4").contains(range("10.2.3.4")), "an address contains itself")
    expectTrue(range("0.0.0.0/0").contains(range("203.0.113.9")), "v4 default route holds any v4")

    // The families never mix. The byte widths differ, so a partial compare
    // would read past the end of the shorter array.
    expectFalse(range("0.0.0.0/0").contains(range("2001:db8::1")), "v4 /0 does not hold a v6")
    expectFalse(range("::/0").contains(range("10.2.3.4")), "v6 /0 does not hold a v4")

    expectTrue(range("2001:db8::/32").contains(range("2001:db8::1")), "v6 host inside its /32")
    expectFalse(range("2001:db8::/32").contains(range("2001:db9::1")), "v6 host outside its /32")
    expectTrue(range("::/0").contains(range("2001:db8::1")), "v6 default route holds any v6")

    // Every prior v6 case uses a byte-aligned prefix, so v6 never reached the
    // mask branch above. Not load-bearing — the mask code does not branch on
    // family — but cheap, so it gets covered too.
    expectTrue(range("2001:db8::/36").contains(range("2001:db8:fff::1")), "v6 held within a non-byte-aligned prefix")
    expectFalse(range("2001:db8::/36").contains(range("2001:db8:1000::1")), "v6 outside a non-byte-aligned prefix")

    print(failures == 0 ? "\nAll CIDRRange checks passed" : "\n\(failures) FAILED")
    if failures > 0 { exit(1) }
}
