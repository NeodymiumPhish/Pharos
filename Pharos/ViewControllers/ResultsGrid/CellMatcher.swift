import Foundation

/// The ONE rule the results Find field matches a cell by.
///
/// Built once per search from the pattern and Settings ▸ Results ▸ Find, then
/// asked about every cell — so the regular expression is compiled once rather
/// than per cell, and the find pass and the filter pass (which run over the
/// same rows one after the other) cannot answer differently.
///
/// Matches RAW cell text, never the escaped display string. See the note at
/// the top of `ResultsFindController`: searching the escaped form would answer
/// a different question than the user asked.
///
/// Foundation only — no AppKit — so `scripts/test-cell-matcher.sh` compiles it
/// standalone.
struct CellMatcher {

    let pattern: String
    let mode: FindMode
    let matchCase: Bool

    /// Whether the pattern could be understood. Only a malformed regular
    /// expression makes this false; `contains` and `wholeWord` accept any
    /// text. An invalid matcher matches NOTHING — the alternative, matching
    /// everything, would silently present the whole result as a hit.
    let isValid: Bool

    /// An empty pattern matches every cell, which is what "no query yet"
    /// means. Callers that want no highlights at all check the pattern for
    /// emptiness themselves rather than asking this type.
    private let matchesEverything: Bool

    private let regex: NSRegularExpression?
    private let compareOptions: String.CompareOptions

    init(pattern: String, mode: FindMode, matchCase: Bool) {
        self.pattern = pattern
        self.mode = mode
        self.matchCase = matchCase
        self.compareOptions = matchCase ? [] : [.caseInsensitive]
        self.matchesEverything = pattern.isEmpty

        guard !pattern.isEmpty else {
            self.regex = nil
            self.isValid = true
            return
        }

        switch mode {
        case .contains:
            self.regex = nil
            self.isValid = true
        case .wholeWord:
            // The pattern is LITERAL text in this mode, so it is escaped
            // before the word boundaries are wrapped around it — a user
            // searching for `a.b` must not get a wildcard.
            let literal = NSRegularExpression.escapedPattern(for: pattern)
            self.regex = try? NSRegularExpression(
                pattern: "\\b\(literal)\\b",
                options: matchCase ? [] : [.caseInsensitive])
            // A word-boundary wrap around escaped text always compiles, so a
            // nil here would be an internal fault, not the user's pattern.
            self.isValid = true
        case .regularExpression:
            let compiled = try? NSRegularExpression(
                pattern: pattern,
                options: matchCase ? [] : [.caseInsensitive])
            self.regex = compiled
            self.isValid = compiled != nil
        }
    }

    /// Whether this cell's raw text is a hit.
    func matches(_ text: String) -> Bool {
        if matchesEverything { return true }
        guard isValid else { return false }
        switch mode {
        case .contains:
            return text.range(of: pattern, options: compareOptions) != nil
        case .wholeWord, .regularExpression:
            guard let regex else { return false }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }
}
