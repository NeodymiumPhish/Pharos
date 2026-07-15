import Foundation

/// Renders token-form SQL (`{{name}}`) into executable SQL by substituting
/// user-defined variable values. Pure logic — no AppKit, unit-tested standalone.
enum VariableSubstitutor {

    struct Invalid: Equatable {
        let name: String
        let reason: String
    }

    struct Result: Equatable {
        var sql: String
        var unresolved: [String]   // token names present but not defined (dedup, in order)
        var invalid: [Invalid]     // defined but value failed type validation
    }

    /// `{{ name }}` — double braces, optional inner whitespace, identifier only.
    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}"#
    )

    /// SQL numeric literal: optional sign, integer/decimal (no exponent).
    private static let numberRegex = try! NSRegularExpression(
        pattern: #"^[+-]?(\d+(\.\d+)?|\.\d+)$"#
    )

    private static let trueSet: Set<String> = ["true", "t", "1", "yes", "y"]
    private static let falseSet: Set<String> = ["false", "f", "0", "no", "n"]

    /// True if the text contains at least one `{{name}}` token.
    static func containsTokens(_ sql: String) -> Bool {
        let ns = sql as NSString
        return tokenRegex.firstMatch(in: sql, range: NSRange(location: 0, length: ns.length)) != nil
    }

    static func render(_ sql: String, with variables: [QueryVariable]) -> Result {
        // Last definition wins on duplicate names.
        var byName: [String: QueryVariable] = [:]
        for variable in variables { byName[variable.name] = variable }

        let ns = sql as NSString
        let full = NSRange(location: 0, length: ns.length)

        var out = ""
        var lastEnd = 0
        var unresolved: [String] = []
        var invalid: [Invalid] = []

        tokenRegex.enumerateMatches(in: sql, range: full) { match, _, _ in
            guard let match else { return }
            let whole = match.range
            let name = ns.substring(with: match.range(at: 1))

            // Text before this token, verbatim.
            out += ns.substring(with: NSRange(location: lastEnd, length: whole.location - lastEnd))
            lastEnd = whole.location + whole.length

            guard let variable = byName[name] else {
                if !unresolved.contains(name) { unresolved.append(name) }
                out += ns.substring(with: whole)  // leave token verbatim
                return
            }

            let formatted = format(variable)
            if let rendered = formatted.value {
                out += rendered
            } else {
                invalid.append(Invalid(name: name, reason: formatted.reason ?? "invalid value"))
                out += ns.substring(with: whole)  // leave token verbatim
            }
        }

        // Trailing text after the last token.
        out += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return Result(sql: out, unresolved: unresolved, invalid: invalid)
    }

    private static func format(_ variable: QueryVariable) -> (value: String?, reason: String?) {
        let raw = variable.value
        switch variable.type {
        case .literal:
            return (raw, nil)
        case .text:
            return ("'" + raw.replacingOccurrences(of: "'", with: "''") + "'", nil)
        case .number:
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let ns = trimmed as NSString
            let ok = numberRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil
            if ok { return (trimmed, nil) }
            return (nil, "not a valid number: \(raw.debugDescription)")
        case .bool:
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if trueSet.contains(key) { return ("true", nil) }
            if falseSet.contains(key) { return ("false", nil) }
            return (nil, "not a valid boolean: \(raw.debugDescription)")
        case .null:
            return ("NULL", nil)
        }
    }
}
