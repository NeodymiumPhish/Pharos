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
    ///
    /// `[0-9]` rather than `\d`: ICU's `\d` matches all of Unicode category Nd, so
    /// `٤٤٣`, `１２３` and `१२३` used to validate, render bare into the SQL, and be
    /// lexed by Postgres as identifiers — the user saw `column "٤٤٣" does not
    /// exist` instead of "not a valid number".
    ///
    /// `\A`/`\z` rather than `^`/`$`: ICU's `$` also matches before a single
    /// trailing line terminator, so `"443\n"` validated and then rendered with the
    /// newline still attached. `\z` is the hard end of input a reader expects here.
    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\A[+-]?([0-9]+(\.[0-9]+)?|\.[0-9]+)\z"#
    )

    private static let trueSet: Set<String> = ["true", "t", "1", "yes", "y"]
    private static let falseSet: Set<String> = ["false", "f", "0", "no", "n"]
    /// `Bool`'s third value. Only the one spelling — unlike true/false, nothing
    /// hand-types this: the detail level offers it as a choice.
    private static let nullSet: Set<String> = ["null"]

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
    /// whether any SQL references it — see `rowStates(in:referenced:)`.
    static func problem(for variable: QueryVariable) -> ValueProblem? {
        switch variable.type {
        case .literal:
            return variable.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .emptyLiteral : nil
        case .text:
            // Renders '' — a legal empty string, and plausibly what was meant.
            return nil
        case .number, .bool:
            let formatted = format(variable)
            guard formatted.value == nil else { return nil }
            return .invalidValue(reason: formatted.reason ?? "invalid value")
        }
    }

    /// What a variables-list row should say about itself. Duplication and failure
    /// are independent: the effective definition of a duplicated name can also be
    /// unable to render, in which case both fields are set.
    struct RowState: Equatable {
        /// Where this row sits among the rows sharing its name. `nil` when the
        /// name is unique.
        ///
        /// The user-facing wording for each case is deliberately not here, unlike
        /// `ValueProblem.message`. `ValueProblem.message` works as one string
        /// because it's the same tooltip everywhere; duplication copy differs by
        /// surface (a terse list caption vs. a full sentence in the detail view),
        /// so it lives with the views that render each surface, not the model.
        enum Duplication: Equatable {
            /// An earlier duplicate. `render(_:with:)` takes a later definition
            /// instead, so this row's value never reaches the query — it is inert,
            /// which the panel says out loud rather than leaving the user to
            /// wonder why editing it changes nothing.
            case shadowed
            /// The last duplicate: the definition `render(_:with:)` actually uses.
            case overriding
        }

        var duplication: Duplication?

        /// Why this row's value cannot become working SQL. Never set on a
        /// `.shadowed` row — it cannot break a query it does not reach.
        var problem: ValueProblem?
    }

    /// What every row should say about itself, keyed by variable id. Ids with
    /// nothing to report are absent.
    ///
    /// Presence in the dictionary means the row has *something* to say, not that
    /// anything is wrong — a healthy row that merely overrides an earlier
    /// duplicate is present too, same as any duplicated row of a name nothing
    /// references. Branch on `.problem` for failure and `.duplication` for
    /// inertness; never treat presence itself as an error.
    ///
    /// List-at-a-time because both rules need the whole list: `render(_:with:)`
    /// resolves a repeated name last-definition-wins, so which row can fail — and
    /// which row is inert — depends on what else is defined.
    static func rowStates(
        in variables: [QueryVariable],
        referenced: Set<String>
    ) -> [UUID: RowState] {
        // Last-wins, matching render()'s own resolution, plus occurrence counts so
        // we know which names are duplicated at all. Skipping unnamed/blank-named
        // variables here is the single thing that keeps a freshly added row —
        // name still empty, or later trimmed to nothing — out of both signals:
        // with no entry in either map, the loop below can find nothing to say
        // about it. Two rows both named "" (or both " ") must not badge each
        // other as duplicates — neither can ever be referenced (tokenRegex
        // requires a leading identifier character), so "duplicate" isn't a
        // meaningful thing to say about them. The map keys themselves stay
        // untrimmed: a real name like " ip " is still distinct from "ip" and
        // simply never matches anything, which `problem(for:)` and `render(_:with:)`
        // already agree on.
        var effective: [String: UUID] = [:]
        var occurrences: [String: Int] = [:]
        for variable in variables where !variable.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effective[variable.name] = variable.id
            occurrences[variable.name, default: 0] += 1
        }

        var states: [UUID: RowState] = [:]
        for variable in variables {
            let isEffective = effective[variable.name] == variable.id
            var state = RowState()

            if (occurrences[variable.name] ?? 0) > 1 {
                state.duplication = isEffective ? .overriding : .shadowed
            }
            if isEffective, referenced.contains(variable.name) {
                state.problem = problem(for: variable)
            }

            guard state.duplication != nil || state.problem != nil else { continue }
            states[variable.id] = state
        }
        return states
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
            // Newlines too, not just spaces: a value pasted from a spreadsheet or
            // a terminal arrives with a trailing line break, and the regex anchors
            // to the hard end of input, so an untrimmed one would now be rejected
            // outright rather than silently rendered into the SQL.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = trimmed as NSString
            let ok = numberRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil
            if ok { return (trimmed, nil) }
            return (nil, "not a valid number: \(raw.debugDescription)")
        case .bool:
            // Three values, not two: NULL is a Bool value rather than a variable
            // type of its own. Rendered uppercase because it is a SQL keyword, not
            // a boolean literal — `true`/`false` stay lowercase.
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if trueSet.contains(key) { return ("true", nil) }
            if falseSet.contains(key) { return ("false", nil) }
            if nullSet.contains(key) { return ("NULL", nil) }
            return (nil, "not a valid boolean: \(raw.debugDescription)")
        }
    }
}
