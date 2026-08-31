import Foundation

/// The one rule for what a result-tab rename commits.
///
/// A result tab's name is normally derived from its query — `L1-3: users` — and
/// follows the statement as the editor text moves. `ResultTab.customLabel`
/// overrides that, permanently, so committing one is a decision and not just a
/// text assignment. Two typed strings must therefore mean "no override":
///
/// - **Empty.** Clearing the field is the only way back to the derived name,
///   so it has to be a supported answer rather than a refused one.
/// - **Exactly the derived name.** The rename dialog prefills with the name on
///   screen, so a user who opens it and presses Rename without typing would
///   otherwise freeze `L1-3: users` as a custom name and the tab would silently
///   stop tracking its statement. Nothing the user did says they wanted that.
///
/// Pure, and free of AppKit and of the model layer, so
/// `scripts/test-result-tab-name.sh` can compile it on its own.
enum ResultTabName {

    /// The custom name a rename commits, or `nil` to restore the derived name.
    ///
    /// - Parameters:
    ///   - typed: the raw contents of the rename field.
    ///   - automatic: the tab's derived name (`ResultTab.automaticLabel`).
    static func committed(_ typed: String, automatic: String) -> String? {
        // `AuthoredLabelSanitizer.committed` is the single producer for every
        // authored label on its way to the store: it denies entry to the
        // scalars that let a name misrepresent itself, then trims. Sanitise
        // BEFORE comparing with `automatic` — otherwise a name padded with a
        // no-break space reads as different here and identical on screen.
        let name = AuthoredLabelSanitizer.committed(typed)
        if name.isEmpty { return nil }
        if name == automatic { return nil }
        return name
    }

    /// The name derived from the query itself — `L1-3: users`.
    ///
    /// `lineRange` is where the statement sits in the editor: 1-based and
    /// inclusive. A lower bound of 0 means the result came from NO editor
    /// segment — a browse action, a whole-editor run, a drill, or a result
    /// reopened from a workspace recorded before the range was stored. The
    /// `L…:` prefix is then left off, because `L0: users` states a line the
    /// statement is not on.
    ///
    /// The subject is the statement's primary table, or the first line of the
    /// SQL when no table can be read out of it.
    static func derived(lineRange: ClosedRange<Int>, sql: String) -> String {
        let subject = tableName(in: sql) ?? sqlPreview(of: sql)
        guard let lines = lineLabel(lineRange) else { return subject }
        return "\(lines): \(subject)"
    }

    /// `L4`, `L4-6`, or nil when there is no editor line range.
    private static func lineLabel(_ range: ClosedRange<Int>) -> String? {
        guard range.lowerBound > 0 else { return nil }
        if range.count == 1 { return "L\(range.lowerBound)" }
        return "L\(range.lowerBound)-\(range.upperBound)"
    }

    /// Extract the primary table name from a SQL statement. Handles
    /// SELECT/DELETE FROM, INSERT INTO and UPDATE, with an optional schema
    /// prefix and quoted identifiers.
    private static func tableName(in sql: String) -> String? {
        let pattern = #"(?i)(?:FROM|INTO|UPDATE)\s+(?:(?:"[^"]+"|[\w]+)\s*\.\s*)?(?:"([^"]+)"|(\w+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)) else {
            return nil
        }
        // Group 1: quoted table name, group 2: unquoted.
        if let range1 = Range(match.range(at: 1), in: sql), !sql[range1].isEmpty {
            return String(sql[range1])
        }
        if let range2 = Range(match.range(at: 2), in: sql), !sql[range2].isEmpty {
            return String(sql[range2])
        }
        return nil
    }

    /// The statement's first line, cut to 30 characters. `Result` when there is
    /// nothing to show: a name has to be visible, and an empty tab is not.
    private static func sqlPreview(of sql: String) -> String {
        let firstLine = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        if firstLine.isEmpty { return "Result" }
        return firstLine.count > 30 ? String(firstLine.prefix(30)) + "…" : firstLine
    }
}
