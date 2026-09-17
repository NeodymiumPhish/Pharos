import Foundation

/// One ranked way to chart a result.
struct ChartRecommendation: Equatable {
    var config: ChartConfig
    /// Short label for a menu, e.g. "Line — revenue over order_date", "Bar — count by status", "Histogram — price".
    var title: String
    /// One plain sentence saying why, e.g. "order_date is a time column and revenue is a measure, so a line shows the trend."
    var reason: String
}

/// A deterministic chart recommender: the rules Tableau's Show Me, Voyager,
/// Excel's Recommended Charts and ggplot2 agree on, applied to `ColumnProfile`s.
///
/// Pure Foundation. Works from profiles (counts, flags, spans) and never from
/// the rows, so it can run on every result without touching cell values.
///
/// Vocabulary, in the order the rules use it:
/// - a MEASURE is `profile.isMeasure`;
/// - a DIMENSION is `profile.isDimension` and neither an identifier nor
///   unique — a unique text column labels rows, it does not group them
///   (the gantt label is the one place a unique column serves);
/// - TEMPORAL is `kind == .temporal`;
/// - a LOW-CARD dimension has at most `lowCardinality` distinct values and
///   can split a chart into series.
enum ChartRecommender {

    /// A dimension with this many distinct values or fewer may split a chart into series.
    static let lowCardinality = 8
    /// A dimension with this many distinct values or fewer is a comfortable bar/heatmap axis.
    static let axisCardinality = 25
    /// A pie has at most this many slices.
    static let pieSlices = 7

    /// Convenience: profiles the result then recommends.
    static func recommend(_ result: QueryResult) -> [ChartRecommendation] {
        recommend(profiles: ColumnProfiler.profile(result), columns: result.columns)
    }

    /// Ranked, best first. Never empty when there is at least one column: the
    /// last entry is always the legacy fallback (`ChartConfig.infer(from: columns)`)
    /// if nothing better applies, deduplicated by (chartType, mappings).
    static func recommend(profiles: [ColumnProfile], columns: [ColumnDef]) -> [ChartRecommendation] {
        guard !columns.isEmpty else { return [] }
        let ctx = Context(profiles: profiles, columns: columns)

        var out: [ChartRecommendation] = []
        out += gantt(ctx)
        out += lines(ctx)
        let bars = barFamily(ctx)
        if bars.isEmpty {
            // No dimension to group by: two measures against each other beat anything else.
            out += scatter(ctx)
            out += heatmap(ctx)
        } else {
            out += bars
            out += heatmap(ctx)
            out += scatter(ctx)
        }
        out += histogram(ctx)
        out += countBar(ctx)
        out += fallback(ctx, othersEmpty: out.isEmpty)
        return dedup(out)
    }

    // MARK: - Context

    /// The profiles sorted into the buckets the rules read.
    private struct Context {
        let columns: [ColumnDef]
        /// Every profile that points at a real column and holds at least one value
        /// (a zero-row result keeps every column: there is nothing to sniff, so the
        /// declared types decide).
        let usable: [ColumnProfile]
        /// Index order.
        let measures: [ColumnProfile]
        /// Best first: see `dimensionRank`.
        let dimensions: [ColumnProfile]
        /// Index order.
        let temporals: [ColumnProfile]

        init(profiles: [ColumnProfile], columns: [ColumnDef]) {
            self.columns = columns
            usable = profiles.filter { $0.index < columns.count && ($0.sampledRows == 0 || $0.nonNullCount > 0) }
            measures = usable.filter(\.isMeasure)
            dimensions = usable
                .filter { $0.isDimension && !$0.looksLikeIdentifier && !$0.isUnique }
                .sorted { Context.dimensionRank($0) < Context.dimensionRank($1) }
            temporals = usable.filter { $0.kind == .temporal }
        }

        func ref(_ p: ColumnProfile) -> ColumnRef { ColumnRef(index: p.index, name: columns[p.index].name) }

        /// Fewest distinct values (above one) wins; a wide axis, a flag, a time
        /// column and a constant each fall behind. Ties break on column order.
        static func dimensionRank(_ p: ColumnProfile) -> (Int, Int, Int, Int, Int, Int) {
            (p.distinctCount > axisCardinality ? 1 : 0,
             p.isBoolean ? 1 : 0,
             p.kind == .temporal ? 1 : 0,
             p.distinctCount <= 1 ? 1 : 0,
             p.distinctCount,
             p.index)
        }

        /// The best dimension other than `excluding`, optionally capped in cardinality.
        func dimension(excluding: Set<Int>, maxDistinct: Int? = nil, minDistinct: Int = 0,
                       allowTemporal: Bool = true) -> ColumnProfile? {
            dimensions.first { d in
                !excluding.contains(d.index)
                    && d.distinctCount >= minDistinct
                    && (maxDistinct.map { d.distinctCount <= $0 } ?? true)
                    && (allowTemporal || d.kind != .temporal)
            }
        }

        /// A dimension that can split a chart into series: low cardinality, at
        /// least two values, not a time column, not one of `excluding`.
        func series(excluding: Set<Int>) -> ColumnProfile? {
            dimension(excluding: excluding, maxDistinct: lowCardinality, minDistinct: 2, allowTemporal: false)
        }

        /// The (category, value) pair a bar reads. A measure that is not also a
        /// dimension (a wide numeric column) is the value when there is one;
        /// two discrete numerics (`rating` 1..5 and `price` with six values)
        /// are settled by the dimension rank, so the narrower one groups.
        var barPair: (dimension: ColumnProfile, measure: ColumnProfile)? {
            let pure = measures.filter { !$0.isDimension }
            let candidates = pure.isEmpty ? measures : pure
            for d in dimensions {
                if let m = candidates.first(where: { $0.index != d.index }) { return (d, m) }
            }
            return nil
        }
    }

    // MARK: - Rules

    /// 1. A label plus two time columns: each row is a span.
    private static func gantt(_ ctx: Context) -> [ChartRecommendation] {
        guard ctx.temporals.count >= 2 else { return [] }
        let labels = ctx.usable.filter { $0.kind == .categorical }
        // A name beats a key, a key beats nothing.
        guard let label = labels.first(where: { !$0.looksLikeIdentifier }) ?? labels.first else { return [] }

        let start: ColumnProfile
        let finish: ColumnProfile
        if let end = ctx.temporals.first(where: { looksLikeEnd($0.name) }),
           let other = ctx.temporals.first(where: { $0.index != end.index }) {
            start = other
            finish = end
        } else {
            start = ctx.temporals[0]
            finish = ctx.temporals[1]
        }

        var cfg = base(.gantt)
        cfg.mappings[.label] = ctx.ref(label)
        cfg.mappings[.start] = ctx.ref(start)
        cfg.mappings[.end] = ctx.ref(finish)
        return [ChartRecommendation(
            config: cfg,
            title: "Gantt — \(label.name) from \(start.name) to \(finish.name)",
            reason: "\(label.name) names each row and \(start.name) and \(finish.name) are time columns, so a Gantt shows every span on one time axis.")]
    }

    /// 2. A time column and a measure: the trend, one line per measure, and a
    /// split by a low-cardinality dimension right after the first.
    private static func lines(_ ctx: Context) -> [ChartRecommendation] {
        guard let time = ctx.temporals.first, !ctx.measures.isEmpty else { return [] }
        var out: [ChartRecommendation] = []
        for (i, m) in ctx.measures.enumerated() {
            let fn = aggregation(forMeasureNamed: m.name)
            var cfg = base(.line)
            cfg.mappings[.category] = ctx.ref(time)
            cfg.mappings[.value] = ctx.ref(m)
            cfg.aggregation = fn
            out.append(ChartRecommendation(
                config: cfg,
                title: "Line — \(m.name) over \(time.name)",
                reason: "\(time.name) is a time column and \(m.name) is a measure, so a line shows the trend of the \(describe(fn)) of \(m.name)."))

            if i == 0, let s = ctx.series(excluding: [time.index, m.index]) {
                var split = cfg
                split.mappings[.series] = ctx.ref(s)
                out.append(ChartRecommendation(
                    config: split,
                    title: "Line — \(m.name) over \(time.name) by \(s.name)",
                    reason: "\(s.name) has only \(s.distinctCount) values, so one line per \(s.name) compares them over \(time.name)."))
            }
        }
        return out
    }

    /// 3 + 4. A dimension and a measure: the bar, the bar split by a second
    /// low-cardinality dimension, then the pie when the parts make a whole.
    private static func barFamily(_ ctx: Context) -> [ChartRecommendation] {
        guard let (d, m) = ctx.barPair else { return [] }
        let fn = aggregation(forMeasureNamed: m.name)
        var out: [ChartRecommendation] = []

        var bar = base(.bar)
        bar.mappings[.category] = ctx.ref(d)
        bar.mappings[.value] = ctx.ref(m)
        bar.aggregation = fn
        bar.display.sort = sort(for: d)
        out.append(ChartRecommendation(
            config: bar,
            title: "Bar — \(m.name) by \(d.name)",
            reason: "\(d.name) has \(d.distinctCount) distinct values and \(m.name) is a measure, so a bar compares the \(describe(fn)) of \(m.name) per \(d.name)."))

        if let s = ctx.series(excluding: [m.index, d.index]) {
            var split = bar
            split.mappings[.series] = ctx.ref(s)
            out.append(ChartRecommendation(
                config: split,
                title: "Bar — \(m.name) by \(d.name) and \(s.name)",
                reason: "\(s.name) has only \(s.distinctCount) values, so stacking it inside each \(d.name) bar shows how the parts make the total."))
        }

        if d.kind != .temporal, (2...pieSlices).contains(d.distinctCount), m.allNonNegative {
            var pie = bar
            pie.chartType = .pie
            pie.mappings[.series] = nil
            out.append(ChartRecommendation(
                config: pie,
                title: "Pie — \(m.name) by \(d.name)",
                reason: "\(d.name) has only \(d.distinctCount) values and \(m.name) is never negative, so a pie shows each \(d.name)'s share of the whole."))
        }
        return out
    }

    /// 5. Two measures against each other; a third sizes the dots.
    private static func scatter(_ ctx: Context) -> [ChartRecommendation] {
        guard ctx.measures.count >= 2 else { return [] }
        let x = ctx.measures[0], y = ctx.measures[1]
        var cfg = base(.scatter)
        cfg.mappings[.x] = ctx.ref(x)
        cfg.mappings[.y] = ctx.ref(y)
        var title = "Scatter — \(y.name) vs \(x.name)"
        var reason = "\(x.name) and \(y.name) are both measures, so a scatter shows how one moves with the other."
        if ctx.measures.count >= 3 {
            let z = ctx.measures[2]
            cfg.mappings[.size] = ctx.ref(z)
            title += ", sized by \(z.name)"
            reason = "\(x.name) and \(y.name) are both measures, so a scatter shows how one moves with the other, with \(z.name) as the dot size."
        }
        return [ChartRecommendation(config: cfg, title: title, reason: reason)]
    }

    /// 6. Two dimensions, each a comfortable axis: a cell per pair.
    private static func heatmap(_ ctx: Context) -> [ChartRecommendation] {
        let m = ctx.barPair?.measure ?? ctx.measures.first
        let taken: Set<Int> = m.map { [$0.index] } ?? []
        guard let x = ctx.dimension(excluding: taken, maxDistinct: axisCardinality, minDistinct: 2),
              let y = ctx.dimension(excluding: taken.union([x.index]), maxDistinct: axisCardinality, minDistinct: 2)
        else { return [] }

        var cfg = base(.heatmap)
        cfg.mappings[.x] = ctx.ref(x)
        cfg.mappings[.y] = ctx.ref(y)
        if let m {
            let fn = aggregation(forMeasureNamed: m.name)
            cfg.mappings[.value] = ctx.ref(m)
            cfg.aggregation = fn
            return [ChartRecommendation(
                config: cfg,
                title: "Heatmap — \(m.name) by \(x.name) and \(y.name)",
                reason: "\(x.name) and \(y.name) are both dimensions, so a heatmap shows the \(describe(fn)) of \(m.name) for every pair.")]
        }
        cfg.aggregation = .count
        return [ChartRecommendation(
            config: cfg,
            title: "Heatmap — count by \(x.name) and \(y.name)",
            reason: "\(x.name) and \(y.name) are both dimensions and there is no measure, so a heatmap counts the rows for every pair.")]
    }

    /// 7. One measure and nothing to group by: its distribution.
    private static func histogram(_ ctx: Context) -> [ChartRecommendation] {
        guard ctx.measures.count == 1, ctx.temporals.isEmpty else { return [] }
        let m = ctx.measures[0]
        guard ctx.dimension(excluding: [m.index]) == nil else { return [] }
        var cfg = base(.bar)
        cfg.mappings[.category] = ctx.ref(m)
        cfg.aggregation = .count
        cfg.numericBin = .auto
        return [ChartRecommendation(
            config: cfg,
            title: "Histogram — \(m.name)",
            reason: "\(m.name) is the only measure and there is nothing to group by, so a histogram shows how its values are spread.")]
    }

    /// 8. A dimension and no measure: rows per value.
    private static func countBar(_ ctx: Context) -> [ChartRecommendation] {
        guard ctx.measures.isEmpty, let d = ctx.dimension(excluding: []) else { return [] }
        var cfg = base(.bar)
        cfg.mappings[.category] = ctx.ref(d)
        cfg.aggregation = .count
        cfg.display.sort = sort(for: d)
        return [ChartRecommendation(
            config: cfg,
            title: "Bar — count by \(d.name)",
            reason: "\(d.name) is a dimension and the result has no measure, so a bar counts the rows per \(d.name).")]
    }

    /// 9. What earlier versions did: first category column, first numeric
    /// column. A key is never a value, whatever its type says; and a half
    /// mapping is only worth listing when nothing else is.
    private static func fallback(_ ctx: Context, othersEmpty: Bool) -> [ChartRecommendation] {
        var cfg = ChartConfig.infer(from: ctx.columns)
        cfg.display = ChartDisplayOptions()
        if let v = cfg.mappings[.value], ctx.usable.first(where: { $0.index == v.index })?.looksLikeIdentifier == true {
            cfg.mappings[.value] = nil
        }
        let cat = cfg.mappings[.category]?.name
        let val = cfg.mappings[.value]?.name
        guard othersEmpty || (cat != nil && val != nil) else { return [] }
        let title: String
        switch (cat, val) {
        case let (c?, v?): title = "Bar — \(c) and \(v)"
        case let (c?, nil): title = "Bar — \(c)"
        case let (nil, v?): title = "Bar — \(v)"
        case (nil, nil): title = "Bar"
        }
        return [ChartRecommendation(
            config: cfg,
            title: title,
            reason: "The first category column against the first numeric column, the way Pharos charted before it looked at the data.")]
    }

    // MARK: - Helpers

    /// A config with the display defaults and empty titles: axis titles come
    /// from `ChartAxisTitles`, the chart title from the user.
    private static func base(_ type: ChartType) -> ChartConfig {
        ChartConfig(chartType: type, display: ChartDisplayOptions())
    }

    /// Categories sort by size; a time or numeric axis keeps its natural order.
    private static func sort(for dimension: ColumnProfile) -> ChartSort {
        dimension.kind == .categorical ? .valueDesc : .queryOrder
    }

    private static func describe(_ fn: AggregationFn) -> String {
        switch fn {
        case .sum: return "sum"
        case .avg: return "average"
        case .count: return "count"
        case .min: return "minimum"
        case .max: return "maximum"
        }
    }

    private static func looksLikeEnd(_ name: String) -> Bool {
        let tokens = words(in: name)
        let endWords: Set<String> = ["end", "ends", "ended", "finish", "finished", "stop", "stopped", "until", "to", "completed", "complete", "done", "closed"]
        return tokens.contains { endWords.contains($0) }
    }

    /// Names that average rather than sum: a rate, a price, a score is already
    /// per-something, and adding two of them means nothing.
    private static let averagedWords: Set<String> = [
        "avg", "average", "mean", "rate", "rates", "ratio", "ratios", "pct", "percent", "percentage",
        "price", "prices", "score", "scores", "temperature", "temp", "latency", "rating", "ratings",
    ]

    /// `.avg` for a measure whose name says it is already a per-unit quantity, else `.sum`.
    static func aggregation(forMeasureNamed name: String) -> AggregationFn {
        let lower = name.lowercased()
        if lower.contains("duration_ms") { return .avg }
        return words(in: name).contains { averagedWords.contains($0) } ? .avg : .sum
    }

    /// Lowercased word tokens: split on `_`, `-`, space, `.`, digits and camelCase humps.
    static func words(in name: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previousWasLower = false
        for ch in name {
            if ch.isLetter {
                if ch.isUppercase, previousWasLower, !current.isEmpty {
                    tokens.append(current); current = ""
                }
                current.append(ch.lowercased())
                previousWasLower = ch.isLowercase
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
                previousWasLower = false
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Keep the first of any two that share a chart type and a mapping.
    private static func dedup(_ list: [ChartRecommendation]) -> [ChartRecommendation] {
        var out: [ChartRecommendation] = []
        for r in list where !out.contains(where: { $0.config.chartType == r.config.chartType && $0.config.mappings == r.config.mappings }) {
            out.append(r)
        }
        return out
    }
}

extension ChartConfig {
    /// The top recommendation for a loaded result, falling back to `infer(from: columns)`.
    static func infer(from result: QueryResult) -> ChartConfig {
        ChartRecommender.recommend(result).first?.config ?? infer(from: result.columns)
    }
}
