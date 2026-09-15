import Foundation

/// What Pharos does to a draft between the model answering and the editor
/// showing it.
///
/// Two jobs, both pure text. It TIDIES what came back — a model that was
/// asked for one statement can still wrap it in a code fence or add a second
/// one after the semicolon — and it REVIEWS the result, so a draft that is
/// not a plain `SELECT` is named as such before the analyst inserts it.
///
/// Nothing here runs anything. The review decides whether the popover asks
/// one more question, never whether the SQL is executed: Pharos does not
/// execute a draft at all.
enum SQLDraftPolicy {

    /// The statement heads a read-only draft may start with.
    ///
    /// `WITH` is here because a common-table expression is how a real analytic
    /// `SELECT` is written, and `EXPLAIN` because asking the planner is a
    /// reading act. A `WITH` that hides a writing CTE — `WITH d AS (DELETE …)`
    /// — is caught by the destructive scan instead, which reads the whole
    /// statement rather than its first word.
    static let readingKeywords: Set<String> = ["SELECT", "WITH", "EXPLAIN"]

    // MARK: - Review

    /// The cleaned draft plus everything the popover needs to decide what to
    /// say about it.
    struct Review: Equatable {

        /// The statement, fenced and trailing statements removed.
        let sql: String

        /// `DROP` / `DELETE` / `TRUNCATE` found outside strings and comments,
        /// uppercased, in first-seen order.
        let destructiveKeywords: [String]

        /// The first word of the statement, uppercased. Empty for an empty
        /// draft or one that is nothing but comments.
        let leadingKeyword: String

        /// The model returned nothing usable.
        var isEmpty: Bool { sql.isEmpty }

        var isDestructive: Bool { !destructiveKeywords.isEmpty }

        /// Whether the statement reads rather than writes.
        var isSelect: Bool { SQLDraftPolicy.readingKeywords.contains(leadingKeyword) }

        /// Whether the analyst is asked to confirm before the draft is
        /// inserted. An empty draft is refused outright, not confirmed.
        var needsConfirmation: Bool { !isEmpty && (isDestructive || !isSelect) }

        /// One sentence naming what is wrong, or nil when nothing is.
        var warning: String? {
            guard needsConfirmation else { return nil }
            if isDestructive {
                let keywords = destructiveKeywords.joined(separator: ", ")
                return String(
                    localized: "This draft is not a plain SELECT: it contains \(keywords).")
            }
            return String(
                localized: "This draft is not a plain SELECT: it starts with \(leadingKeyword).")
        }
    }

    /// Clean `raw` and report on the result.
    static func review(_ raw: String) -> Review {
        let sql = clean(raw)
        return Review(
            sql: sql,
            destructiveKeywords: DestructiveSQLScanner.destructiveKeywords(in: sql),
            leadingKeyword: leadingKeyword(of: sql))
    }

    /// Convenience for a caller that only wants the verdict.
    static func isDestructive(_ sql: String) -> Bool {
        !DestructiveSQLScanner.destructiveKeywords(in: sql).isEmpty
    }

    // MARK: - Cleaning

    /// Trim, unwrap a code fence, and keep only the first statement.
    static func clean(_ raw: String) -> String {
        var text = stripFence(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        text = firstStatement(of: text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove a ``` fence around the statement.
    ///
    /// The model is asked for a bare statement and usually gives one, but an
    /// answer that arrives fenced would otherwise put ``` into the editor as
    /// a syntax error. Only the FIRST fenced block is taken: a second one is
    /// a second statement, which `firstStatement` would drop anyway.
    private static func stripFence(_ raw: String) -> String {
        guard let open = raw.range(of: "```") else { return raw }

        // The opening fence runs to the end of its line, so an info string
        // (```sql, ```postgresql) goes with it.
        // On a one-line answer — "```sql SELECT 1```" — there is no newline to
        // cut at. The whole remainder is kept: a stray "sql" prefix is visible
        // to the analyst, a silently dropped SELECT is not.
        var body = raw[open.upperBound...]
        if let newline = body.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            body = body[body.index(after: newline)...]
        }

        if let close = body.range(of: "```") {
            body = body[body.startIndex..<close.lowerBound]
        }
        return String(body)
    }

    /// Everything up to and including the first semicolon that is not inside
    /// a string, a quoted identifier, a comment or a dollar-quoted body.
    ///
    /// The semicolon is KEPT: it is where the statement ends, and the editor's
    /// segment parser reads it the same way.
    private static func firstStatement(of sql: String) -> String {
        let chars = Array(sql.utf16)
        guard !chars.isEmpty else { return sql }
        let stateMap = SQLLexer.buildStateMap(chars: chars, length: chars.count)
        let semicolon: unichar = 0x3B
        for i in 0..<chars.count where chars[i] == semicolon && stateMap[i].isNormal {
            return String(utf16CodeUnits: chars, count: i + 1)
        }
        return sql
    }

    // MARK: - Leading keyword

    /// The first word outside a comment, uppercased.
    ///
    /// Comments are skipped rather than trimmed, so a draft the model
    /// introduced with `-- orders per region` is still recognised as a
    /// `SELECT` instead of being flagged as something unknown.
    static func leadingKeyword(of sql: String) -> String {
        let chars = Array(sql.utf16)
        guard !chars.isEmpty else { return "" }
        let stateMap = SQLLexer.buildStateMap(chars: chars, length: chars.count)

        var word = ""
        for i in 0..<chars.count {
            let ch = chars[i]
            let isLetter = (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || ch == 0x5F
            if stateMap[i].isNormal, isLetter {
                if let scalar = Unicode.Scalar(ch) { word.append(Character(scalar)) }
            } else if !word.isEmpty {
                break
            }
        }
        return word.uppercased()
    }
}
