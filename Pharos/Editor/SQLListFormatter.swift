import Foundation

/// Pure helpers for the "Format as SQL list" feature: detecting when pasted
/// text looks like a bare value list, and transforming it into a quoted,
/// comma-separated SQL list. No AppKit dependencies — unit-tested standalone
/// via scripts/test-sql-list-formatter.sh.
enum SQLListFormatter {

    private static let maxLines = 5_000
    private static let maxLineLength = 1_000

    /// Keywords that strongly indicate SQL. Short ambiguous words (IN, OR,
    /// ON, AS, AND, BY) are deliberately excluded — they can be legitimate
    /// values (e.g. US state codes). Real SQL queries have multi-token lines
    /// and fail the single-token rule anyway.
    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "update", "delete", "join",
        "create", "alter", "drop", "union", "having", "values", "limit",
    ]

    /// True when the text looks like a bare multi-line value list worth
    /// offering to SQL-ize: 2+ non-empty lines, mostly single tokens, no
    /// strong SQL keywords, and not already a quoted comma-separated list.
    static func looksLikeBareList(_ text: String) -> Bool {
        let rawLines = text.components(separatedBy: .newlines)
        guard rawLines.count <= maxLines else { return false }

        let lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }
        guard lines.allSatisfy({ $0.count <= maxLineLength }) else { return false }

        for line in lines {
            let words = line.lowercased().split(whereSeparator: { !$0.isLetter })
            if words.contains(where: { sqlKeywords.contains(String($0)) }) { return false }
        }

        let singleTokenCount = lines.filter { !$0.contains(" ") && !$0.contains("\t") }.count
        guard Double(singleTokenCount) >= 0.8 * Double(lines.count) else { return false }

        if isAlreadyFormattedList(lines) { return false }

        return true
    }

    /// True when every line is a quoted token (optionally comma-terminated)
    /// and at least one comma is present — i.e. the work is already done.
    private static func isAlreadyFormattedList(_ lines: [String]) -> Bool {
        var sawComma = false
        for line in lines {
            var token = line
            if token.hasSuffix(",") {
                sawComma = true
                token = String(token.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            guard token.count >= 2,
                  (token.hasPrefix("'") && token.hasSuffix("'"))
                      || (token.hasPrefix("\"") && token.hasSuffix("\""))
            else { return false }
        }
        return sawComma
    }

    /// Transform line-separated values into a SQL list: one value per line,
    /// comma after every value except the last, leading indentation kept.
    /// Values are normalized (existing commas/quotes stripped) then quoted
    /// unless the whole list is numeric, boolean, or NULL.
    static func sqlize(_ text: String) -> String {
        struct Item {
            let indent: String
            let token: String
        }

        var items: [Item] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }
            let indent = String(rawLine.prefix(while: { $0 == " " || $0 == "\t" }))
            items.append(Item(indent: indent, token: normalize(trimmedLine)))
        }
        guard !items.isEmpty else { return text }

        let quote = shouldQuote(items.map { $0.token })

        var outLines: [String] = []
        for (i, item) in items.enumerated() {
            var value = item.token
            if quote {
                value = "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
            }
            let comma = i < items.count - 1 ? "," : ""
            outLines.append(item.indent + value + comma)
        }
        return outLines.joined(separator: "\n")
    }

    /// Strip one trailing comma, then one layer of wrapping quotes. A
    /// single-quoted wrapper also collapses doubled '' back to ' so that
    /// re-escaping in sqlize doesn't double pre-escaped input.
    private static func normalize(_ token: String) -> String {
        var t = token
        if t.hasSuffix(",") {
            t = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard t.count >= 2 else { return t }
        if t.hasPrefix("'") && t.hasSuffix("'") {
            t = String(t.dropFirst().dropLast())
            t = t.replacingOccurrences(of: "''", with: "'")
        } else if t.hasPrefix("\"") && t.hasSuffix("\"") {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    /// Quote unless EVERY token is numeric, or every token is a boolean, or
    /// every token is NULL. Quoted numerics are valid in Postgres IN lists;
    /// unquoted strings are a syntax error — so bias toward quoting.
    private static func shouldQuote(_ tokens: [String]) -> Bool {
        if tokens.allSatisfy({ $0.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil }) {
            return false
        }
        if tokens.allSatisfy({ ["true", "false"].contains($0.lowercased()) }) {
            return false
        }
        if tokens.allSatisfy({ $0.lowercased() == "null" }) {
            return false
        }
        return true
    }
}
