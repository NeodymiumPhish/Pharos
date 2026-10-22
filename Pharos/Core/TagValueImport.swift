import Foundation

/// Add Values…: a pasted or typed list, one value per line, each line one rule
/// with one condition. The type is detected from the value, the way an analyst
/// would pick it in the rule row:
///
/// | Value | Family | Operator |
/// |---|---|---|
/// | `10.0.0.0/8`, `2001:db8::/32` | Address | in range |
/// | `10.0.0.1`, `::1` | Address | is |
/// | `42`, `-3.5` | Number | is |
/// | `2026-10-22`, `2026-10-22T16:02:00Z` | Date & time | is |
/// | `550e8400-e29b-41d4-a716-446655440000` | UUID | is |
/// | `*.example.com`, `user_?` | Text | matches |
/// | anything else | Text | is |
///
/// A value that LOOKS like an address or range but does not parse
/// (`10.0.0.300`, `10.0.0.0/40`) is refused, not quietly made a text rule:
/// it is a typo, and a text rule for it would never match the address meant.
///
/// Every condition goes through `TagConditionEditor.condition`, the same gate
/// the rule row uses, so a value the matcher would refuse is shown as such and
/// never added. Blank lines are left out; a repeated line, or one the tag
/// already has as a one-condition rule, is shown and not added. Pure
/// (`scripts/test-tag-value-import.sh`).
enum TagValueImport {
    struct Line: Equatable {
        enum Status: Equatable {
            case ready
            case repeated
            case alreadyInTag
            case invalid(String)
        }

        let text: String
        let family: String
        let kind: TagConditionKind
        let condition: TagCondition?
        let status: Status

        /// "Address · in range".
        var typeLabel: String {
            "\(TagFamilyLabel.text(for: family)) · \(TagConditionEditor.label(for: kind, family: family))"
        }
    }

    static func detect(_ raw: String) -> (family: String, kind: TagConditionKind) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if CIDRRange.parse(text) != nil {
            return (TagValueNormalizer.addressFamily, text.contains("/") ? .cidr : .exact)
        }
        if UUID(uuidString: text) != nil {
            return (TagValueNormalizer.uuidFamily, .exact)
        }
        if TagValueNormalizer.isNumericText(text) {
            return (TagValueNormalizer.numericFamily, .exact)
        }
        if TagValueNormalizer.canonicalTimestamp(text) != nil {
            return (TagValueNormalizer.temporalFamily, .exact)
        }
        if text.contains("*") || text.contains("?") {
            return (TagValueNormalizer.textFamily, .glob)
        }
        return (TagValueNormalizer.textFamily, .exact)
    }

    /// `existing`: the conditions of the tag's rules, one array per rule.
    /// Digits, dots and colons (hex for IPv6), with an optional "/n", and at
    /// least one separator: the shape of an address, whether or not it is one.
    static func looksLikeAddress(_ text: String) -> Bool {
        guard text.contains(".") || text.contains(":"), !TagValueNormalizer.isNumericText(text) else { return false }
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let address = parts[0]
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
        guard !address.isEmpty, address.unicodeScalars.allSatisfy(hex.contains),
              address.contains(where: \.isNumber) else { return false }
        return parts.count == 1 || parts[1].allSatisfy(\.isNumber)
    }

    static func lines(from text: String, existing: [[TagCondition]]) -> [Line] {
        func key(_ c: TagCondition) -> String { "\(c.family)\u{1F}\(c.kind.rawValue)\u{1F}\(c.value)" }
        let inTag = Set(existing.filter { $0.count == 1 }.map { key($0[0]) })
        var seen: Set<String> = []
        var result: [Line] = []
        for raw in text.split(whereSeparator: \.isNewline).map(String.init) {
            let value = raw.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            let (family, kind) = detect(value)
            if family != TagValueNormalizer.addressFamily, looksLikeAddress(value) {
                result.append(Line(text: value, family: TagValueNormalizer.addressFamily,
                                   kind: value.contains("/") ? .cidr : .exact, condition: nil,
                                   status: .invalid(String(localized: "Not a valid address or range."))))
                continue
            }
            switch TagConditionEditor.condition(family: family, kind: kind, value: value, operand2: "") {
            case .failure(let invalid):
                result.append(Line(text: value, family: family, kind: kind, condition: nil,
                                   status: .invalid(Self.reason(invalid))))
            case .success(let condition):
                let k = key(condition)
                let status: Line.Status = inTag.contains(k) ? .alreadyInTag : seen.contains(k) ? .repeated : .ready
                seen.insert(k)
                result.append(Line(text: value, family: family, kind: kind, condition: condition, status: status))
            }
        }
        return result
    }

    /// The conditions to add: one per ready line, in order.
    static func readyConditions(_ lines: [Line]) -> [TagCondition] {
        lines.compactMap { $0.status == .ready ? $0.condition : nil }
    }

    private static func reason(_ invalid: TagConditionEditor.Invalid) -> String {
        switch invalid {
        case .unparseable(let message): return message
        default: return String(localized: "Not a value this type can match.")
        }
    }
}
