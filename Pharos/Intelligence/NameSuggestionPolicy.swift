import Foundation

/// Which list the suggested name will appear in.
///
/// The three places differ only in the sentence that opens the prompt: a saved
/// query lives in a library beside other people's names, a result tab sits
/// under an editor, an editor tab is the whole document. The model writes a
/// better name when it is told which.
enum NameSuggestionKind {
    case savedQuery
    case resultTab
    case editorTab

    /// The first line of the prompt. Plain English, no SQL.
    var promptLine: String {
        switch self {
        case .savedQuery: return "Name a saved query for a library of saved queries."
        case .resultTab: return "Name one result of a query, shown as a small tab."
        case .editorTab: return "Name an editor tab that holds this query."
        }
    }
}

/// Everything about the "suggest a name" feature that does not need the model:
/// what is put in the prompt, and what is done to the answer before it reaches
/// a text field.
///
/// Pure Foundation, and deliberately so. The model cannot be run in a test, but
/// the two halves that decide whether the feature is any good — what is sent
/// and what is accepted back — can be, and are, in
/// `scripts/test-name-suggestion.sh`.
enum NameSuggestionPolicy {

    // MARK: - Limits

    /// How much SQL goes in the prompt. A statement longer than this says what
    /// it returns in its first lines anyway, and the rest only spends context.
    static let maxSQLLength = 2000

    /// How long a suggested name may be. Longer than this and a tab label is
    /// all ellipsis, which is worse than "Query 4".
    static let maxTitleLength = 40

    /// Marks SQL that was cut, so the model does not read a truncated
    /// statement as a complete one.
    static let truncationMarker = "\n-- (truncated)"

    // MARK: - Instructions

    /// Appended after `IntelligenceInstructions.sqlSafety`.
    static let instructions = """
        Suggest a short name for this SQL query for a human list. Two to four \
        words. Describe what the query returns, not how.
        """

    // MARK: - The prompt

    /// The prompt for one suggestion.
    ///
    /// Schema names and the statement only: a query's SQL and the tables it
    /// mentions are metadata, and no row value can reach here — nothing in the
    /// call chain has one.
    ///
    /// - Parameters:
    ///   - sql: the statement, capped at `maxSQLLength`.
    ///   - tables: the table names the statement mentions, as
    ///     `PharosCore.extractTableNames` returns them. Nil or empty is fine —
    ///     the SQL still carries them, this line only makes them easy to find.
    ///   - folders: the folders a saved query could go in. Empty for a tab.
    static func prompt(sql: String, tables: String?, folders: [String], kind: NameSuggestionKind) -> String {
        var lines: [String] = [kind.promptLine]

        if let tables, !tables.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Tables: \(tables)")
        }

        let named = folders.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if named.isEmpty {
            lines.append("Folders: none — leave the folder empty.")
        } else {
            lines.append("Folders: \(named.joined(separator: ", "))")
        }

        lines.append("SQL:")
        lines.append(cappedSQL(sql))
        return lines.joined(separator: "\n")
    }

    /// The statement, cut to `maxSQLLength` characters with the cut declared.
    static func cappedSQL(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxSQLLength else { return trimmed }
        return String(trimmed.prefix(maxSQLLength)) + truncationMarker
    }

    // MARK: - The answer

    /// The name to put in the field, or `fallback` when the model gave nothing
    /// usable.
    ///
    /// A generated name is an AUTHORED LABEL the moment it lands in a text
    /// field the user can save, so it goes through the same sanitiser a typed
    /// one does — a model that echoed a bidi override out of a column comment
    /// must not be able to seed a deceptive name.
    static func title(from raw: String, fallback: String) -> String {
        var text = AuthoredLabelSanitizer.sanitized(raw)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripWrappingQuotes(text)
        // "Recent Orders by Region." — a name is not a sentence, and the stop
        // is the one piece of punctuation the model adds most often.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!"))
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = titleCased(text)
        text = capped(text)
        return text.isEmpty ? fallback : text
    }

    /// The suggested folder, but only when it is one the user already has.
    ///
    /// The model is asked to pick FROM the list, and mostly does; a name it
    /// invented would silently create a folder the user never asked for, so an
    /// unknown one is dropped rather than offered. The match ignores case and
    /// the stored spelling wins, so "reports" selects the existing "Reports"
    /// instead of making a second folder next to it.
    static func folder(from raw: String?, in folders: [String]) -> String? {
        guard let raw else { return nil }
        let wanted = AuthoredLabelSanitizer.sanitized(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return folders.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    // MARK: - Text shaping

    private static func stripWrappingQuotes(_ text: String) -> String {
        let quotes: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}")]
        for (open, close) in quotes where text.count >= 2 && text.first == open && text.last == close {
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Title Case, but it will not touch an identifier.
    ///
    /// A word that is nothing but letters gets its first letter raised.
    /// Anything else — `pg_class`, `v2`, `orders.id` — is left exactly as the
    /// model wrote it, because raising the first letter of an identifier makes
    /// a name that no longer matches the object it names. The very first word
    /// is raised either way: a name that opens lower-case reads as a mistake.
    static func titleCased(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let raised = words.enumerated().map { index, word -> String in
            let isPlainWord = word.allSatisfy { $0.isLetter }
            guard isPlainWord || index == 0 else { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return raised.joined(separator: " ")
    }

    /// At most `maxTitleLength` characters, cut at a word boundary when there
    /// is one — "Counts of Every Relation Kind in the Catalogue" reads better
    /// cut to "Counts of Every Relation Kind in the" than to a half word.
    static func capped(_ text: String) -> String {
        guard text.count > maxTitleLength else { return text }
        let head = String(text.prefix(maxTitleLength))
        if let lastSpace = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: lastSpace) >= 8 {
            return String(head[head.startIndex..<lastSpace]).trimmingCharacters(in: .whitespaces)
        }
        return head.trimmingCharacters(in: .whitespaces)
    }
}
