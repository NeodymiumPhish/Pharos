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

    /// Why a variable's value cannot become working SQL. `nil` means it can.
    enum ValueProblem: Equatable {
        /// A `Literal` whose value is empty or whitespace-only: it renders to
        /// nothing, leaving a hole such as `WHERE ip_addr = `.
        case emptyLiteral
        /// A `Number` or `Bool` whose value fails validation. `reason` is the
        /// message `format(_:)` produces, so the panel badge and the pre-flight
        /// guard describe the failure identically.
        case invalidValue(reason: String)

        /// Human-readable explanation, shown as the panel's tooltip.
        var message: String {
            switch self {
            case .emptyLiteral:
                return "Referenced in the query but has no value — the query will fail."
            case .invalidValue(let reason):
                return "Referenced in the query but the value is \(reason)."
            }
        }
    }

    /// Whether the substitutor already knows this variable's value cannot
    /// become working SQL: an empty/whitespace `Literal`, or a `Number`/`Bool`
    /// that fails the validation `format(_:)` performs. Not exhaustive — a
    /// `Literal` is a raw-SQL escape hatch, so a value like `"'"` or `")"` can
    /// still produce broken SQL and returns `nil` here. Says nothing about
    /// whether any SQL references it — see `displayProblems(in:referenced:)`.
    static func problem(for variable: QueryVariable) -> ValueProblem? {
        switch variable.type {
        case .literal:
            return variable.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .emptyLiteral : nil
        case .text, .null:
            // Text renders '' (a legal empty string); Null ignores the value.
            return nil
        case .number, .bool:
            let formatted = format(variable)
            guard formatted.value == nil else { return nil }
            return .invalidValue(reason: formatted.reason ?? "invalid value")
        }
    }

    /// The problems worth showing the user, keyed by variable id. Absent id =
    /// nothing to flag.
    ///
    /// Deliberately list-at-a-time. `render(_:with:)` resolves duplicate names
    /// last-definition-wins, so a row whose name is shadowed by a later row has
    /// no effect on the query and must not be flagged — a per-variable entry
    /// point could not express that, and would paint a red "the query will
    /// fail" badge on a row belonging to a query that succeeds.
    static func displayProblems(
        in variables: [QueryVariable],
        referenced: Set<String>
    ) -> [UUID: ValueProblem] {
        // Same last-wins resolution render() uses, so the row we flag is the one
        // whose value actually reaches the query. Skipping unnamed variables here
        // is the single thing that keeps a freshly added row — name still empty —
        // from being flagged: with no entry in this map, nothing below can match
        // it, whatever the caller passed as `referenced`.
        var effective: [String: UUID] = [:]
        for variable in variables where !variable.name.isEmpty {
            effective[variable.name] = variable.id
        }

        var problems: [UUID: ValueProblem] = [:]
        for variable in variables {
            guard referenced.contains(variable.name),
                  effective[variable.name] == variable.id,
                  let problem = problem(for: variable)
            else { continue }
            problems[variable.id] = problem
        }
        return problems
    }

    /// Every `{{name}}` referenced in the text, deduplicated. Uses the same
    /// regex `render(_:with:)` substitutes with — including tokens inside string
    /// literals, which `render` also substitutes — so the panel cannot disagree
    /// with what actually runs.
    static func referencedNames(in sql: String) -> Set<String> {
        let ns = sql as NSString
        var names: Set<String> = []
        tokenRegex.enumerateMatches(in: sql, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            names.insert(ns.substring(with: match.range(at: 1)))
        }
        return names
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
