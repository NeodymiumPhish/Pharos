import Foundation

/// The one line a menu shows for a `{{name}}`: what the token puts into the
/// query when it runs, so the user can tell before running. That is the
/// RENDERED text (`VariableSubstitutor.render`, the same call that runs), not
/// the stored value: a list renders as `('a', 'b')` and a date as a `DATE`
/// literal, and an empty Literal renders nothing.
///
/// Pure (Foundation only), tested by `scripts/test-variable-menu-preview.sh`.
enum VariableMenuPreview {

    enum Preview: Equatable {
        /// No variable this tab can use has the name.
        case undefined
        /// The value renders to nothing visible.
        case empty
        /// The value cannot render; `reason` says why.
        case invalid(reason: String)
        /// The first line with content, at most `limit` characters.
        case value(String, truncated: Bool)
    }

    /// Longest text a menu row shows; a longer value ends in "…".
    static let limit = 60

    /// `variables` are the ones this tab can use (`VariableScope`); the last
    /// definition of a name wins, as in `render`.
    static func preview(for name: String, variables: [QueryVariable]) -> Preview {
        let result = VariableSubstitutor.render("{{\(name)}}", with: variables)
        if result.unresolved.contains(name) { return .undefined }
        if let problem = result.invalid.first(where: { $0.name == name }) { return .invalid(reason: problem.reason) }
        let lines = result.sql.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty }
        guard let first else { return .empty }
        let more = lines.drop { $0 != first }.dropFirst().contains { !$0.isEmpty }
        guard first.count > limit else { return .value(first, truncated: more) }
        return .value(String(first.prefix(limit)), truncated: true)
    }

    /// The menu row's text.
    static func text(_ preview: Preview) -> String {
        switch preview {
        case .undefined:
            return String(localized: "Undefined: no variable has this name")
        case .empty:
            return String(localized: "Renders as nothing (no value)")
        case .invalid(let reason):
            return String(localized: "Cannot render: \(reason)")
        case let .value(text, truncated):
            return String(localized: "Renders as \(text + (truncated ? "…" : ""))")
        }
    }
}
