import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - CIDRRange

/// An IPv4 or IPv6 address with an optional prefix length.
///
/// Its ONE job is canonical text for the address family of the tag normalizer:
/// two spellings of one address must produce one string, so that a tagged
/// `2001:0DB8::0001` matches a probed `2001:db8::1`.
///
/// It does NOT answer containment. The superseded value-tag design matched an
/// address predicate by CIDR membership; the unified model matches by a hash
/// probe on `(family, normalized value)`, and a hash cannot answer "is this
/// address inside that prefix". A `10.2.3.0/24` tag matches the literal value
/// `10.2.3.0/24`, not the hosts inside it. Adding containment back means adding
/// a second, linear matching path — a design decision, not an implementation
/// one.
///
/// `inet_pton` does the parsing: it is the same code the operating system uses,
/// it rejects every malformed spelling (`10.2.3.999`, `10.2.3.4.5`), and it
/// costs nothing to depend on here. Foundation and Darwin only, so the
/// standalone harness compiles this file on its own.
struct CIDRRange: Equatable {

    /// 4 bytes for IPv4, 16 for IPv6, in network order.
    let bytes: [UInt8]
    /// 0…32 for IPv4, 0…128 for IPv6. Defaults to the full width.
    let prefixLength: Int

    var isIPv6: Bool { bytes.count == 16 }

    /// Private so `parse` is the ONLY constructor. The whole type rests on
    /// `bytes` being exactly 4 or 16 wide — `canonicalText` hands that array
    /// straight to `inet_ntop`, which reads the width the family says, not the
    /// width the array has. A synthesised memberwise init is internal, so any
    /// file in the target could otherwise build a 3-byte value and make
    /// `inet_ntop` read past the end of its storage.
    private init(bytes: [UInt8], prefixLength: Int) {
        self.bytes = bytes
        self.prefixLength = prefixLength
    }

    /// Parse `10.2.3.4`, `10.2.3.0/24`, `2001:db8::1` or `2001:db8::/32`.
    /// Returns nil for anything else — never a partial parse, never a trap.
    static func parse(_ text: String) -> CIDRRange? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "/", maxSplits: 1,
                                  omittingEmptySubsequences: false)
        let addressText = String(parts[0])

        var v4 = [UInt8](repeating: 0, count: 4)
        var v6 = [UInt8](repeating: 0, count: 16)
        let bytes: [UInt8]
        if addressText.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            bytes = v4
        } else if addressText.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            bytes = v6
        } else {
            return nil
        }

        let width = bytes.count * 8
        var prefix = width
        if parts.count == 2 {
            // A prefix that is absent is "the whole address"; a prefix that is
            // PRESENT and unreadable is a malformed value, and a malformed
            // value must never match — silently treating it as /32 would let a
            // typo match a real host.
            guard let given = Int(parts[1]), given >= 0, given <= width else { return nil }
            prefix = given
        }
        return CIDRRange(bytes: bytes, prefixLength: prefix)
    }

    /// The one spelling this address compares by: `inet_ntop`'s form, with a
    /// full-width prefix omitted.
    var canonicalText: String {
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = isIPv6 ? AF_INET6 : AF_INET
        let text: String = bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  let converted = inet_ntop(family, base, &out,
                                            socklen_t(INET6_ADDRSTRLEN))
            else {
                // Dead with the private init above: `bytes` is always 4 or 16 wide
                // and the family always matches it, so `inet_ntop` cannot fail.
                // Kept anyway, because trapping here would crash the app on a
                // database value. Hex, NOT a dotted join: every real `inet_ntop`
                // spelling holds a "." or a ":", so this can never collide with a
                // genuine address, and two different corrupt values still differ.
                return bytes.map { String(format: "%02x", $0) }.joined()
            }
            return String(cString: converted)
        }
        return prefixLength == bytes.count * 8 ? text : "\(text)/\(prefixLength)"
    }

    /// Does this range hold `other`?
    ///
    /// The question `canonicalText` deliberately cannot answer. The superseded
    /// value-tag design matched an address by CIDR membership; the unified
    /// model matches by a hash probe, and a hash cannot answer containment. A
    /// `cidr` CONDITION is the second, linear path that can.
    ///
    /// Three gates, and each one is a real failure without it:
    ///
    ///  - Different byte widths never compare. A v4 range holding a v6 value
    ///    would compare 4 bytes of a 16-byte address and call a stranger a
    ///    match — and `bytes[index]` past the shorter array would trap.
    ///  - A range only holds something at least as SPECIFIC as itself. Without
    ///    this, `10.2.3.0/24` would "hold" `10.0.0.0/8`, because the /8's first
    ///    24 bits agree with it.
    ///  - The trailing partial byte is masked. A prefix that is not a multiple
    ///    of 8 leaves bits in the last byte that belong to the host, not the
    ///    network, and comparing them whole rejects every real member.
    func contains(_ other: CIDRRange) -> Bool {
        guard bytes.count == other.bytes.count else { return false }
        guard prefixLength <= other.prefixLength else { return false }

        let whole = prefixLength / 8
        for index in 0..<whole where bytes[index] != other.bytes[index] {
            return false
        }

        let spare = prefixLength % 8
        guard spare > 0 else { return true }
        // `~(UInt8.max >> spare)`, NOT `UInt8(0xFF << (8 - spare))`: the second
        // one computes in `Int` and traps initialising a `UInt8` the moment
        // `spare < 8`, which is every case that reaches this line.
        let mask: UInt8 = ~(UInt8.max >> UInt8(spare))
        return (bytes[whole] & mask) == (other.bytes[whole] & mask)
    }

    /// The canonical text of `text`, or nil when it is not an address.
    static func canonical(_ text: String) -> String? {
        parse(text)?.canonicalText
    }
}
