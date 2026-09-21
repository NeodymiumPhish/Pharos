import Foundation

/// Pure display-string formatting for partition metadata. Foundation-only,
/// so it is unit-testable standalone — it names the two partition enums in
/// `Schema.swift`, which its harness compiles alongside.
enum PartitionDisplay {

    /// Extract the parenthesized column list from a pg_get_partkeydef string.
    /// "RANGE (created_at)" -> "created_at"; "LIST (region, tier)" -> "region, tier".
    static func keyColumns(fromPartKeyDef def: String?) -> String? {
        guard let def = def,
              let open = def.firstIndex(of: "("),
              let close = def.lastIndex(of: ")"),
              open < close else { return nil }
        let inner = def[def.index(after: open)..<close]
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The inspector's heading for a parent. Declarative partitioning and
    /// legacy inheritance are different mechanisms, and the heading is the
    /// one place a person can see which one they are looking at.
    static func parentHeading(mechanism: PartitionMechanism?) -> String {
        mechanism == .inheritance ? "Inherited Table" : "Partitioned Table"
    }

    /// The note under a child that is itself a parent, or nil when it is a
    /// leaf. It must never print a question mark: an inheritance child has no
    /// strategy to read, and "Sub-partitioned by ?" is what that used to say.
    static func subParentNote(
        isParent: Bool,
        strategy: PartitionStrategy?,
        mechanism: PartitionMechanism?,
        childCount: Int64?
    ) -> String? {
        guard isParent else { return nil }
        if let strategy { return "Sub-partitioned by \(strategy.badgeLabel)" }
        if mechanism == .inheritance { return "Inherited by \(childCount ?? 0) more" }
        return nil
    }

    /// Compact one-line summary of a partition bound for the leaf subtitle.
    static func boundSummary(_ bound: String?) -> String? {
        guard let bound = bound else { return nil }
        let b = bound.trimmingCharacters(in: .whitespaces)
        if b == "DEFAULT" { return "DEFAULT" }

        if let fromR = b.range(of: "FROM ("), let toR = b.range(of: ") TO (") {
            let from = String(b[fromR.upperBound..<toR.lowerBound]).stripBoundValue()
            let after = b[toR.upperBound...]
            let to = String(after.prefix(while: { $0 != ")" })).stripBoundValue()
            return "[\(from), \(to))"
        }
        if let inR = b.range(of: "IN (") {
            let inner = String(b[inR.upperBound...].prefix(while: { $0 != ")" }))
            let values = inner.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).stripBoundValue() }
                .joined(separator: ", ")
            return "IN (\(values))"
        }
        if let modR = b.range(of: "modulus "), let remR = b.range(of: "remainder ") {
            let modulus = String(b[modR.upperBound...].prefix(while: { $0.isNumber }))
            let remainder = String(b[remR.upperBound...].prefix(while: { $0.isNumber }))
            return "mod \(modulus), rem \(remainder)"
        }
        return b   // unknown form: show raw
    }
}

private extension String {
    /// Strip surrounding quotes and whitespace from a bound literal token.
    func stripBoundValue() -> String {
        trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .trimmingCharacters(in: .whitespaces)
    }
}
