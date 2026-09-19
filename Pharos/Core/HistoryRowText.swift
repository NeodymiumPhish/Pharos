import Foundation

/// Text shown on the rows of the workspace-history list and its preview pane.
/// Pure formatting — no AppKit, no FFI — so `scripts/test-workspace-history-match.sh`
/// can assert it directly.
enum HistoryRowText {
    /// The leading clause of a workspace row's second line, before the relative
    /// date and the connection name.
    ///
    /// While the filter is active, the clause reports how many of the
    /// workspace's queries matched. A workspace with no matching query keeps
    /// the plain clause: it was listed because its name, its editor text, or
    /// its connection name matched, not because a query did.
    ///
    /// - Parameters:
    ///   - total: every query in the workspace.
    ///   - matches: the queries whose SQL matched the active filter.
    ///   - isFiltering: whether the sidebar filter holds any text.
    static func queryClause(total: Int, matches: Int, isFiltering: Bool) -> String {
        let noun = total == 1 ? "query" : "queries"
        guard isFiltering, matches > 0 else {
            return "\(total) \(noun)"
        }
        // The noun agrees with the total; the verb agrees with the match count.
        let verb = matches == 1 ? "matches" : "match"
        return "\(matches) of \(total) \(noun) \(verb)"
    }

    /// Hoisted because this runs once per row on every reload. Both call sites
    /// are on the main thread, and nothing mutates the formatter after this
    /// initialiser, so sharing one instance is safe.
    private static let rowCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    /// A row count with thousands grouping, for both history rows and preview
    /// rows.
    static func rowCountText(_ count: Int64) -> String {
        rowCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    // MARK: - Failed rows

    /// The word a row carries when its run did not produce a result, or nil
    /// when it did.
    ///
    /// A status this build has never heard of reads as "Failed" rather than as
    /// a success: the same rule `HistoryStatusScope::Failed` applies in the
    /// store, so a row can never fall out of both scopes.
    static func statusLabel(_ status: String) -> String? {
        switch status {
        case QueryHistoryStatus.ok: return nil
        case QueryHistoryStatus.cancelled: return String(localized: "Cancelled")
        default: return String(localized: "Failed")
        }
    }

    /// Everything one row of the Results History list says.
    struct LegacyRow: Equatable {
        /// The row's visible text.
        let primary: String
        /// The hover text: what the visible line had no room for.
        let tooltip: String
        /// What VoiceOver reads. A glyph is invisible to a screen reader, so
        /// this must NAME the failure — it can never be the primary text plus
        /// an icon the reader cannot see.
        let accessibilityLabel: String
        /// Whether the row shows the warning glyph.
        let isFailed: Bool
    }

    /// Compose one row of the Results History list.
    ///
    /// Pure, and every string argument arrives ALREADY ESCAPED — the caller
    /// owns `DisplayEscape`, so this file keeps no dependency but Foundation
    /// and six standalone harnesses can still compile it.
    ///
    /// - Parameters:
    ///   - status: `ok`, `error` or `cancelled`. See `QueryHistoryStatus`.
    ///   - errorMessage: what the server said, on a row that failed.
    ///   - columnCount: nil on a failed row — it produced no columns.
    ///   - tableNames: escaped, or empty.
    ///   - firstSQLLine: escaped first line of the SQL, the fallback subject.
    ///   - flatSQL: escaped, one-line, already clipped, for the tooltip.
    ///   - rowCount: nil on a failed row.
    ///   - connectionName: escaped.
    ///   - relativeTime: what the trailing label shows, for the spoken label.
    static func legacyRow(
        status: String,
        errorMessage: String?,
        columnCount: Int64?,
        tableNames: String,
        firstSQLLine: String,
        flatSQL: String,
        rowCount: Int64?,
        connectionName: String,
        relativeTime: String
    ) -> LegacyRow {
        // The subject of the row: what it was about, however little we know.
        let colText: String
        if let columnCount {
            colText = "\(columnCount) Column\(columnCount == 1 ? "" : "s")"
        } else {
            colText = ""
        }
        let subject: String
        if !colText.isEmpty && !tableNames.isEmpty {
            subject = "\(colText) – \(tableNames)"
        } else if !tableNames.isEmpty {
            subject = tableNames
        } else if !colText.isEmpty {
            subject = colText
        } else {
            subject = firstSQLLine
        }

        guard let label = statusLabel(status) else {
            // A successful row, exactly as it has always read.
            var tipParts: [String] = []
            if let rowCount {
                tipParts.append("\(rowCountText(rowCount)) Row\(rowCount == 1 ? "" : "s")")
            }
            tipParts.append(connectionName)
            if !flatSQL.isEmpty { tipParts.append(flatSQL) }
            return LegacyRow(
                primary: subject,
                tooltip: tipParts.joined(separator: " – "),
                accessibilityLabel: [subject, connectionName, relativeTime]
                    .filter { !$0.isEmpty }
                    .joined(separator: ", "),
                isFailed: false
            )
        }

        // A failed row. The word comes FIRST, so the list reads as a list of
        // outcomes rather than as a list of subjects with a decoration.
        let primary = subject.isEmpty ? label : "\(label) – \(subject)"

        // The message is the point of a failed row, so it leads the tooltip.
        var tipParts: [String] = []
        if let errorMessage, !errorMessage.isEmpty {
            tipParts.append("\(label): \(errorMessage)")
        } else {
            tipParts.append(label)
        }
        tipParts.append(connectionName)
        if !flatSQL.isEmpty { tipParts.append(flatSQL) }

        // Spoken: the word, then the message, then the rest. Without the word
        // here the glyph is the only thing that says this row failed, and a
        // screen reader cannot see it.
        var spoken: [String] = [label]
        if let errorMessage, !errorMessage.isEmpty { spoken.append(errorMessage) }
        if !subject.isEmpty { spoken.append(subject) }
        spoken.append(connectionName)
        if !relativeTime.isEmpty { spoken.append(relativeTime) }

        return LegacyRow(
            primary: primary,
            tooltip: tipParts.joined(separator: " – "),
            accessibilityLabel: spoken.filter { !$0.isEmpty }.joined(separator: ", "),
            isFailed: true
        )
    }
}
