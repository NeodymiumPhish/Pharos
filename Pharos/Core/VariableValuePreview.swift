import Foundation

/// How a variable's value is summarised in the variables list: the one-line
/// preview and the size caption above it. Pure string logic, no AppKit — tested
/// standalone by `scripts/test-variable-value-preview.sh`.
enum VariableValuePreview {

    /// Upper bound on `snippet`'s result length. The panel's core use case is a
    /// long comma-joined ID list, which is often a single very long line —
    /// without a cap the row's label would lay out the entire thing.
    private static let snippetLengthLimit = 500

    /// The single line shown as a row's value preview: the first line with any
    /// visible content, tabs flattened to spaces so it cannot grow sideways,
    /// ends trimmed, length capped at `snippetLengthLimit`. Returns "" when
    /// there is no visible content. Note that the row decides whether to show
    /// its `no value` placeholder from `value.isEmpty`, not from this result —
    /// a whitespace-only value is real content that happens to look blank, and
    /// its caption says so.
    static func snippet(for value: String) -> String {
        for line in lines(of: value) {
            let flattened = line.replacingOccurrences(of: "\t", with: " ")
            let trimmed = flattened.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(snippetLengthLimit)) }
        }
        return ""
    }

    /// The size caption. One trailing line break, if present, is not counted —
    /// it is invisible to the user and so shouldn't inflate either count.
    /// What remains is measured in lines when it has more than one, otherwise
    /// in characters.
    static func caption(for value: String) -> String {
        var measured = value
        if measured.hasSuffix("\r\n") {
            measured.removeLast(2)
        } else if measured.hasSuffix("\n") || measured.hasSuffix("\r") {
            measured.removeLast()
        }

        let lineCount = lines(of: measured).count
        if lineCount > 1 { return "\(lineCount) lines" }
        let chars = measured.count
        return chars == 1 ? "1 char" : "\(chars) chars"
    }

    /// Every line break a pasted value may carry (LF, CRLF, CR, VT, U+2028…),
    /// normalised to one representation. Matches how the rest of the app splits
    /// lines — a value pasted from Windows or Excel arrives CRLF-delimited.
    private static func lines(of value: String) -> [String] {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
    }
}
