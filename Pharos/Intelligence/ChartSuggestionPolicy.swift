import Foundation

/// Everything about "suggest a chart" that does not need the model: what is
/// put in the prompt, and what is done to the answer before it becomes a
/// `ChartConfig`.
///
/// Pure Foundation, on purpose. The model cannot run in a test, but the two
/// halves that decide whether the feature is any good — what is sent and what
/// is accepted back — can be, and are, in `scripts/test-chart-suggestion-policy.sh`.
///
/// The prompt carries column names, PostgreSQL types, the SQL and SHAPE
/// statistics (counts, shares, a sign, a span). It never carries a cell value,
/// so the feature runs without a `RowDataConsent` sheet.
enum ChartSuggestionPolicy {

    // MARK: - Limits

    static let maxSQLLength = 2000
    static let maxColumns = 40
    static let maxTitleLength = 60
    static let maxAxisTitleLength = 40
    static let maxReasonLength = 240
    static let truncationMarker = "\n-- (truncated)"

    // MARK: - Instructions

    /// Appended after `IntelligenceInstructions.sqlSafety`.
    static let instructions = """
        You recommend one chart for a PostgreSQL query result. Prefer a line for a \
        measure over time, a bar for a measure by category, a scatter for two \
        measures, a heatmap for two categories, a gantt for a label with a start and \
        an end, and a pie only for parts of a whole with seven or fewer slices. Never \
        chart an identifier as a measure. Use only the column names listed, spelled \
        exactly as listed. Choose one of the numbered candidates or improve on it.
        """

    // MARK: - The prompt

    /// The prompt for one suggestion.
    ///
    /// - Parameters:
    ///   - profiles: one per column, from `ColumnProfiler`.
    ///   - rowCount: rows the result has (loaded), so the model knows the scale.
    ///   - candidates: the deterministic recommender's ranked list, best first.
    ///   - sql: the statement, capped at `maxSQLLength`.
    static func prompt(profiles: [ColumnProfile], rowCount: Int,
                       candidates: [ChartRecommendation], sql: String) -> String {
        var lines: [String] = ["Recommend the best chart for this SQL result."]
        lines.append("Rows: \(rowCount).")
        lines.append("Columns:")
        for p in profiles.prefix(maxColumns) { lines.append("- " + describe(p)) }
        if profiles.count > maxColumns { lines.append("- and \(profiles.count - maxColumns) more columns, not listed.") }
        if !candidates.isEmpty {
            lines.append("Candidates, best first:")
            for (i, c) in candidates.enumerated() { lines.append("\(i + 1). \(c.title). \(c.reason)") }
        }
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("SQL:")
            lines.append(cappedSQL(trimmed))
        }
        lines.append("Answer with the chart type, the columns for each role, the aggregation, a title of at most eight words, axis titles of at most four words, and one sentence of reason.")
        return lines.joined(separator: "\n")
    }

    /// One line of shape for a column. Counts, shares, flags and a span —
    /// never a value.
    static func describe(_ p: ColumnProfile) -> String {
        var parts: [String] = []
        let role: String
        if p.looksLikeIdentifier { role = "identifier" }
        else if p.isBoolean { role = "boolean" }
        else {
            switch p.kind {
            case .temporal: role = "time"
            case .numeric: role = p.isDimension && !p.isMeasure ? "category" : "measure"
            case .categorical: role = "category"
            }
        }
        parts.append(role)
        parts.append("\(p.distinctCount) distinct")
        if p.isUnique { parts.append("unique") }
        let nullPct = Int((p.nullShare * 100).rounded())
        if nullPct > 0 { parts.append("\(nullPct)% null") }
        if p.kind == .numeric && !p.looksLikeIdentifier {
            parts.append(p.allNonNegative ? "non-negative" : "has negatives")
            parts.append(p.allIntegers ? "integers" : "decimals")
        }
        if p.kind == .temporal, let span = p.spanSeconds {
            parts.append("spans \(spanText(span))")
        }
        return "\(p.name) (\(p.dataType)): " + parts.joined(separator: ", ")
    }

    /// "3 hours", "12 days", "3 years" — the coarsest unit that keeps the count above one.
    static func spanText(_ seconds: Double) -> String {
        let hour = 3600.0, day = 86_400.0
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if seconds >= 2 * 365 * day { return plural(Int(seconds / (365 * day)), "year") }
        if seconds >= 2 * day { return plural(Int(seconds / day), "day") }
        if seconds >= hour { return plural(max(1, Int(seconds / hour)), "hour") }
        return "under an hour"
    }

    static func cappedSQL(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxSQLLength else { return trimmed }
        return String(trimmed.prefix(maxSQLLength)) + truncationMarker
    }

    // MARK: - The answer

    /// What the model says, as plain Foundation values.
    ///
    /// A mirror of the `@Generable ChartSuggestion` so the validation below can
    /// be tested without `FoundationModels`. The three column fields mean one
    /// thing per chart type — see `apply`.
    struct Answer: Equatable {
        var chartType: String
        /// The category, the time column, scatter X, heatmap X, or the gantt label.
        var xColumn: String
        /// The measure: value, scatter Y, heatmap value (optional), or the gantt start.
        var yColumn: String?
        /// The optional third column: series (bar/line/area), heatmap Y, scatter size, the gantt end.
        var groupColumn: String?
        var aggregation: String?
        var timeBucket: String?
        var title: String
        var xAxisTitle: String
        var yAxisTitle: String
        var reason: String
    }

    /// Why an answer could not be used. The user never sees these words; the
    /// caller falls back to the top candidate and logs the case.
    enum Rejection: Error, Equatable {
        case unknownChartType(String)
        case unknownColumn(String)
        case roleRefusesColumn(ChartColumnRole, String)
        case missingColumn(ChartColumnRole)
    }

    /// The config the answer describes, checked against the columns.
    ///
    /// Names resolve exactly first, then case-insensitively, then with quotes
    /// stripped; a name that matches several columns takes the first (the
    /// generator refuses ambiguity on its own). Every mapped role must accept
    /// the column's (refined) kind. Titles are sanitised as authored labels
    /// and capped.
    static func apply(_ answer: Answer, profiles: [ColumnProfile]) throws -> ChartConfig {
        guard let type = ChartType(rawValue: answer.chartType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw Rejection.unknownChartType(answer.chartType)
        }
        func resolve(_ raw: String?) throws -> ColumnProfile? {
            guard let raw else { return nil }
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            if name.isEmpty || name == "—" || name.lowercased() == "none" || name.lowercased() == "nil" { return nil }
            if let p = profiles.first(where: { $0.name == name }) { return p }
            if let p = profiles.first(where: { $0.name.lowercased() == name.lowercased() }) { return p }
            throw Rejection.unknownColumn(raw)
        }
        let x = try resolve(answer.xColumn)
        let y = try resolve(answer.yColumn)
        let group = try resolve(answer.groupColumn)

        var cfg = ChartConfig(chartType: type)
        let agg = AggregationFn(rawValue: (answer.aggregation ?? "").lowercased()) ?? .sum
        cfg.aggregation = agg

        func map(_ role: ChartColumnRole, _ p: ColumnProfile?, required: Bool) throws {
            guard let p else {
                if required { throw Rejection.missingColumn(role) }
                return
            }
            guard ChartRoleEligibility.accepts(role, kind: p.kind, chartType: type) else {
                throw Rejection.roleRefusesColumn(role, p.name)
            }
            cfg.mappings[role] = ColumnRef(index: p.index, name: p.name)
        }
        switch type {
        case .bar, .line, .area:
            try map(.category, x, required: true)
            try map(.value, y, required: agg != .count)
            try map(.series, group, required: false)
        case .pie:
            try map(.category, x, required: true)
            try map(.value, y, required: agg != .count)
        case .scatter:
            try map(.x, x, required: true)
            try map(.y, y, required: true)
            try map(.size, group, required: false)
        case .heatmap:
            try map(.x, x, required: true)
            try map(.y, group, required: true)
            try map(.value, y, required: false)
            if y == nil { cfg.aggregation = .count }
        case .gantt:
            try map(.label, x, required: true)
            try map(.start, y, required: true)
            try map(.end, group, required: true)
        }
        if let bucket = answer.timeBucket?.lowercased(), let bin = TemporalBin(rawValue: bucket) {
            cfg.temporalBin = bin
        }
        // A bar over a category the model calls out is best read largest first.
        if type == .bar, let x, x.kind == .categorical { cfg.display.sort = .valueDesc }
        cfg.display.title = label(answer.title, cap: maxTitleLength)
        cfg.display.xAxisTitle = label(answer.xAxisTitle, cap: maxAxisTitleLength)
        cfg.display.yAxisTitle = label(answer.yAxisTitle, cap: maxAxisTitleLength)
        return cfg
    }

    /// A generated title is an AUTHORED LABEL the moment it is drawn as the
    /// chart's own caption and saved with the workspace, so it goes through
    /// the same sanitiser a typed one does.
    static func label(_ raw: String, cap: Int) -> String {
        var text = AuthoredLabelSanitizer.sanitized(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripWrappingQuotes(text)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!"))
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.count > cap {
            text = String(text.prefix(cap)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        return text
    }

    /// The reason as one sentence for the caption: sanitised, single-spaced,
    /// capped, ending in a full stop.
    static func reason(_ raw: String) -> String {
        var text = AuthoredLabelSanitizer.sanitized(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.count > maxReasonLength {
            text = String(text.prefix(maxReasonLength)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        if text.isEmpty { return "" }
        if let last = text.last, !".!?\u{2026}".contains(last) { text += "." }
        return text
    }

    private static func stripWrappingQuotes(_ s: String) -> String {
        var t = s
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}")]
        for (open, close) in pairs where t.count >= 2 && t.first == open && t.last == close {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
