import Foundation

/// How a variable's value is summarised in the variables list: the one-line
/// preview and the size caption above it. Pure string logic, no AppKit — tested
/// standalone by `scripts/test-variable-value-preview.sh`.
enum VariableValuePreview {

    /// The single line shown as a row's value preview: the first line with any
    /// visible content, tabs flattened to spaces so it cannot grow sideways,
    /// ends trimmed. Returns "" when there is no visible content. Note that the
    /// row decides whether to show its `no value` placeholder from
    /// `value.isEmpty`, not from this result — a whitespace-only value is real
    /// content that happens to look blank, and its caption says so.
    static func snippet(for value: String) -> String {
        for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
            let flattened = line.replacingOccurrences(of: "\t", with: " ")
            let trimmed = flattened.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// The size caption. Values containing a newline are counted in lines,
    /// everything else in characters. One trailing newline is not counted as an
    /// extra line, so a 47-entry list pasted with a trailing return reads
    /// `47 lines` rather than `48 lines`.
    static func caption(for value: String) -> String {
        let lines = lineCount(of: value)
        if lines > 1 { return "\(lines) lines" }
        let chars = value.count
        return chars == 1 ? "1 char" : "\(chars) chars"
    }

    private static func lineCount(of value: String) -> Int {
        guard !value.isEmpty else { return 0 }
        var newlines = value.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        if value.hasSuffix("\n") { newlines -= 1 }
        return newlines + 1
    }
}
