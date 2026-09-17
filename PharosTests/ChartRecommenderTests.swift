// Standalone test runner for ChartRecommender.
// Compiled by scripts/test-chart-recommender.sh.
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// Helper: build a QueryResult where every cell is a PG-text string (as in prod).
func makeResult(_ columns: [(String, String)], _ rows: [[String?]]) -> QueryResult {
    let cols = columns.map { ColumnDef(name: $0.0, dataType: $0.1) }
    let anyRows = rows.map { row in row.map { AnyCodable($0 as Any?) } }
    return QueryResult(columns: cols, rows: anyRows, rowCount: rows.count,
                       executionTimeMs: 0, hasMore: false, historyEntryId: nil)
}

/// Every mapped role of every recommendation is legal for the column's (refined) kind.
func eligible(_ recs: [ChartRecommendation], _ result: QueryResult) -> Bool {
    let profiles = ColumnProfiler.profile(result)
    return recs.allSatisfy { rec in
        rec.config.mappings.allSatisfy { role, ref in
            guard ref.index < profiles.count, profiles[ref.index].name == ref.name else { return false }
            return ChartRoleEligibility.roles(for: rec.config.chartType).contains(role)
                && ChartRoleEligibility.accepts(role, kind: profiles[ref.index].kind, chartType: rec.config.chartType)
        }
    }
}

func names(_ recs: [ChartRecommendation]) -> [String] { recs.map(\.title) }

func runTests() {
    // --- Time + measure → line first, .auto bin ---
    let daily = makeResult([("order_date", "date"), ("revenue", "numeric")],
                           [["2024-01-01", "100"], ["2024-01-02", "200"], ["2024-01-03", "150"], ["2024-01-04", "175"]])
    let dailyRecs = ChartRecommender.recommend(daily)
    expect(dailyRecs.first?.config.chartType == .line, "time+measure: line first")
    expect(dailyRecs.first?.config.mappings[.category]?.name == "order_date", "time+measure: category = time column")
    expect(dailyRecs.first?.config.mappings[.value]?.name == "revenue", "time+measure: value = measure")
    expect(dailyRecs.first?.config.temporalBin == .auto, "time+measure: temporalBin .auto")
    expect(dailyRecs.first?.config.aggregation == .sum, "time+measure: revenue sums")
    expect(dailyRecs.first?.title == "Line — revenue over order_date", "time+measure: title")
    expect(ChartConfig.infer(from: daily) == dailyRecs.first!.config, "infer(from: result) equals the top recommendation")

    // --- Time + measure + low-card dimension → second is line with series ---
    let regional = makeResult([("order_date", "date"), ("region", "text"), ("revenue", "numeric")],
                              [["2024-01-01", "EU", "100"], ["2024-01-01", "US", "200"],
                               ["2024-01-02", "EU", "150"], ["2024-01-02", "US", "175"],
                               ["2024-01-03", "EU", "120"], ["2024-01-03", "US", "190"]])
    let regionalRecs = ChartRecommender.recommend(regional)
    expect(regionalRecs.first?.config.chartType == .line && regionalRecs.first?.config.mappings[.series] == nil,
           "time+measure+dim: plain line first")
    expect(regionalRecs.count > 1 && regionalRecs[1].config.chartType == .line
           && regionalRecs[1].config.mappings[.series]?.name == "region",
           "time+measure+dim: second is line with series = region")
    expect(regionalRecs.count > 1 && regionalRecs[1].title == "Line — revenue over order_date by region", "time+measure+dim: series title")
    expect(regionalRecs.contains { $0.config.chartType == .bar && $0.config.mappings[.category]?.name == "region" },
           "time+measure+dim: a bar by region follows")

    // --- Text dimension + measure → bar first (valueDesc), pie second ---
    let byStatus = makeResult([("status", "text"), ("amount", "numeric")],
                              [["open", "10"], ["closed", "20"], ["open", "5"], ["pending", "7"]])
    let statusRecs = ChartRecommender.recommend(byStatus)
    expect(statusRecs.first?.config.chartType == .bar, "dim+measure: bar first")
    expect(statusRecs.first?.config.mappings[.category]?.name == "status"
           && statusRecs.first?.config.mappings[.value]?.name == "amount", "dim+measure: bar mapping")
    expect(statusRecs.first?.config.display.sort == .valueDesc, "dim+measure: categorical bar sorts valueDesc")
    expect(statusRecs.count > 1 && statusRecs[1].config.chartType == .pie, "dim+measure: pie second when <= 7 slices and non-negative")
    expect(statusRecs.count > 1 && statusRecs[1].config.mappings[.category]?.name == "status"
           && statusRecs[1].config.mappings[.value]?.name == "amount", "dim+measure: pie mapping")
    expect(statusRecs.first?.config.display.title == "" && statusRecs.first?.config.display.xAxisTitle == ""
           && statusRecs.first?.config.display.yAxisTitle == "", "dim+measure: titles left empty for derivation")
    expect(statusRecs.last?.config == { var c = ChartConfig.infer(from: byStatus.columns); c.display = ChartDisplayOptions(); return c }()
           || !statusRecs.contains { $0.title.hasPrefix("Bar — status and") },
           "dim+measure: fallback identical to the bar is deduplicated")

    // --- No pie when a value is negative ---
    let signed = makeResult([("status", "text"), ("delta", "numeric")],
                            [["open", "10"], ["closed", "-20"], ["pending", "7"]])
    expect(!ChartRecommender.recommend(signed).contains { $0.config.chartType == .pie }, "negative measure: no pie")

    // --- No pie when 9 categories ---
    let nine = makeResult([("code", "text"), ("amount", "numeric")],
                          (1...9).flatMap { i in [["c\(i)", "\(i)"], ["c\(i)", "\(i * 2)"]] })
    let nineRecs = ChartRecommender.recommend(nine)
    expect(nineRecs.first?.config.chartType == .bar, "nine categories: bar still first")
    expect(!nineRecs.contains { $0.config.chartType == .pie }, "nine categories: no pie")

    // --- Two measures only → scatter first ---
    let pair = makeResult([("height", "numeric"), ("weight", "numeric")],
                          [["170", "65"], ["180", "80"], ["160", "55"], ["175", "70"]])
    let pairRecs = ChartRecommender.recommend(pair)
    expect(pairRecs.first?.config.chartType == .scatter, "two measures: scatter first")
    expect(pairRecs.first?.config.mappings[.x]?.name == "height" && pairRecs.first?.config.mappings[.y]?.name == "weight",
           "two measures: x = first, y = second")
    expect(pairRecs.first?.config.mappings[.size] == nil, "two measures: no size")

    // --- Third numeric → size ---
    let triple = makeResult([("height", "numeric"), ("weight", "numeric"), ("age", "integer")],
                            [["170", "65", "30"], ["180", "80", "41"], ["160", "55", "25"], ["175", "70", "37"]])
    let tripleRecs = ChartRecommender.recommend(triple)
    expect(tripleRecs.first?.config.chartType == .scatter && tripleRecs.first?.config.mappings[.size]?.name == "age",
           "three measures: third becomes size")

    // --- Two dimensions + measure → heatmap present with value ---
    let grid = makeResult([("region", "text"), ("product", "text"), ("sales", "numeric")],
                          [["EU", "A", "1"], ["EU", "B", "2"], ["US", "A", "3"], ["US", "B", "4"], ["EU", "A", "5"]])
    let gridRecs = ChartRecommender.recommend(grid)
    let heat = gridRecs.first { $0.config.chartType == .heatmap }
    expect(heat != nil, "two dims + measure: heatmap present")
    expect(heat?.config.mappings[.value]?.name == "sales", "two dims + measure: heatmap value = sales")
    expect(heat?.config.mappings[.x] != nil && heat?.config.mappings[.y] != nil
           && heat?.config.mappings[.x] != heat?.config.mappings[.y], "two dims + measure: heatmap x and y differ")
    expect(gridRecs.first?.config.chartType == .bar, "two dims + measure: bar first")
    expect(gridRecs.contains { $0.config.chartType == .bar && $0.config.mappings[.series] != nil },
           "two dims + measure: a bar with series is offered")

    // --- Two dimensions, no measure → count heatmap, then count bar ---
    let pairsOnly = makeResult([("region", "text"), ("product", "text")],
                               [["EU", "A"], ["EU", "B"], ["US", "A"], ["US", "B"], ["EU", "A"]])
    let pairsRecs = ChartRecommender.recommend(pairsOnly)
    expect(pairsRecs.first?.config.chartType == .heatmap && pairsRecs.first?.config.aggregation == .count
           && pairsRecs.first?.config.mappings[.value] == nil, "two dims no measure: count heatmap first")
    expect(pairsRecs.contains { $0.config.chartType == .bar && $0.config.aggregation == .count }, "two dims no measure: count bar present")

    // --- Single measure → histogram ---
    let prices = makeResult([("price", "numeric")], [["1.5"], ["2.0"], ["3.25"], ["9.0"], ["2.0"]])
    let priceRecs = ChartRecommender.recommend(prices)
    expect(priceRecs.first?.config.chartType == .bar, "single measure: histogram is a bar")
    expect(priceRecs.first?.config.aggregation == .count, "single measure: histogram counts")
    expect(priceRecs.first?.config.numericBin == .auto, "single measure: numericBin .auto")
    expect(priceRecs.first?.config.mappings[.category]?.name == "price" && priceRecs.first?.config.mappings[.value] == nil,
           "single measure: category = the measure, no value")
    expect(priceRecs.first?.title == "Histogram — price", "single measure: histogram title")

    // --- Single dimension → count bar ---
    let statuses = makeResult([("status", "text")], [["open"], ["closed"], ["open"], ["pending"]])
    let statusOnly = ChartRecommender.recommend(statuses)
    expect(statusOnly.first?.config.chartType == .bar && statusOnly.first?.config.aggregation == .count,
           "single dim: count bar first")
    expect(statusOnly.first?.config.mappings[.category]?.name == "status" && statusOnly.first?.config.mappings[.value] == nil,
           "single dim: category = status, no value")
    expect(statusOnly.first?.config.display.sort == .valueDesc, "single dim: count bar sorts valueDesc")
    expect(statusOnly.first?.title == "Bar — count by status", "single dim: count bar title")

    // --- Identifier columns never land on value / y ---
    let keyed = makeResult([("id", "integer"), ("user_uuid", "uuid"), ("status", "text"), ("amount", "numeric")],
                           [["1", "a1", "open", "10"], ["2", "b2", "closed", "20"], ["3", "c3", "open", "5"]])
    let keyedRecs = ChartRecommender.recommend(keyed)
    expect(!keyedRecs.contains { r in
        [ChartColumnRole.value, .y, .x, .size].contains { role in
            ["id", "user_uuid"].contains(r.config.mappings[role]?.name ?? "")
        }
    }, "identifiers: never mapped to value, x, y or size")
    expect(keyedRecs.first?.config.chartType == .bar && keyedRecs.first?.config.mappings[.value]?.name == "amount"
           && keyedRecs.first?.config.mappings[.category]?.name == "status", "identifiers: bar uses status and amount")

    // --- Text column whose values all parse as numbers is a measure ---
    let textNumbers = makeResult([("status", "text"), ("amount", "text")],
                                 [["open", "1.5"], ["closed", "2.0"], ["open", "3.0"]])
    let textRecs = ChartRecommender.recommend(textNumbers)
    expect(textRecs.first?.config.chartType == .bar && textRecs.first?.config.mappings[.value]?.name == "amount",
           "refined kind: numeric-looking text column is the measure")

    // --- Gantt from (task, started_at, ended_at) ---
    let tasks = makeResult([("task", "text"), ("started_at", "timestamp"), ("ended_at", "timestamp")],
                           [["Build", "2024-01-01 09:00:00", "2024-01-01 11:00:00"],
                            ["Test", "2024-01-01 11:00:00", "2024-01-01 12:30:00"],
                            ["Ship", "2024-01-01 13:00:00", "2024-01-01 13:15:00"]])
    let taskRecs = ChartRecommender.recommend(tasks)
    expect(taskRecs.first?.config.chartType == .gantt, "gantt: first")
    expect(taskRecs.first?.config.mappings[.label]?.name == "task"
           && taskRecs.first?.config.mappings[.start]?.name == "started_at"
           && taskRecs.first?.config.mappings[.end]?.name == "ended_at", "gantt: label/start/end mapping")
    expect(taskRecs.first?.config.temporalBin == .auto, "gantt: temporalBin .auto")
    expect(taskRecs.first?.reason.contains("started_at") == true && taskRecs.first?.reason.contains("ended_at") == true,
           "gantt: reason names both time columns")

    // Gantt picks the end-named column even when it comes first.
    let reversed = makeResult([("task", "text"), ("finish", "timestamp"), ("begin", "timestamp")],
                              [["Build", "2024-01-01 11:00:00", "2024-01-01 09:00:00"],
                               ["Test", "2024-01-01 12:30:00", "2024-01-01 11:00:00"]])
    let reversedRecs = ChartRecommender.recommend(reversed)
    expect(reversedRecs.first?.config.mappings[.start]?.name == "begin"
           && reversedRecs.first?.config.mappings[.end]?.name == "finish", "gantt: end-named column is the end")

    // --- Aggregation by name ---
    let avgPrice = makeResult([("region", "text"), ("avg_price", "numeric")],
                              [["EU", "1.5"], ["US", "2.0"], ["EU", "3.0"]])
    expect(ChartRecommender.recommend(avgPrice).first?.config.aggregation == .avg, "avg_price aggregates by average")
    expect(ChartRecommender.aggregation(forMeasureNamed: "unitPrice") == .avg, "camelCase unitPrice averages")
    expect(ChartRecommender.aggregation(forMeasureNamed: "error_rate") == .avg, "error_rate averages")
    expect(ChartRecommender.aggregation(forMeasureNamed: "duration_ms") == .avg, "duration_ms averages")
    expect(ChartRecommender.aggregation(forMeasureNamed: "revenue") == .sum, "revenue sums")
    expect(ChartRecommender.aggregation(forMeasureNamed: "generated") == .sum, "'generated' does not match 'rate' inside a word")
    expect(ChartRecommender.aggregation(forMeasureNamed: "attempts") == .sum, "'attempts' does not match 'temp' inside a word")

    // --- Numeric low-cardinality dimension → bar category, natural order ---
    let ratings = makeResult([("rating", "integer"), ("price", "numeric")],
                             [["1", "5"], ["2", "6"], ["3", "7"], ["4", "8"], ["5", "9"], ["3", "10"]])
    let ratingRecs = ChartRecommender.recommend(ratings)
    expect(ratingRecs.first?.config.chartType == .bar && ratingRecs.first?.config.mappings[.category]?.name == "rating"
           && ratingRecs.first?.config.mappings[.value]?.name == "price", "numeric dim: rating is the category, price the value")
    expect(ratingRecs.first?.config.display.sort == .queryOrder, "numeric dim: bar keeps query order")
    expect(ratingRecs.first?.config.numericBin == .auto, "numeric dim: numericBin .auto")

    // --- Empty columns ---
    let empty = makeResult([], [])
    expect(ChartRecommender.recommend(empty).isEmpty, "no columns: recommend returns []")
    let emptyCfg = ChartConfig.infer(from: empty)
    expect(emptyCfg.chartType == .bar && emptyCfg.mappings.isEmpty, "no columns: infer(from: result) is a bar with no mappings")

    // --- Unique text label + measure → the legacy fallback still charts it ---
    let products = makeResult([("product", "text"), ("revenue", "numeric")],
                              [["A", "1"], ["B", "2"], ["C", "3"]])
    let productRecs = ChartRecommender.recommend(products)
    expect(!productRecs.isEmpty, "unique label + measure: never empty")
    expect(productRecs.last?.config.mappings[.category]?.name == "product"
           && productRecs.last?.config.mappings[.value]?.name == "revenue", "unique label + measure: fallback maps both")
    expect(productRecs.last?.title == "Bar — product and revenue", "unique label + measure: fallback title")

    // --- The invariant over a wide mixed fixture ---
    let mixed = makeResult([("id", "integer"), ("order_date", "date"), ("region", "text"), ("status", "text"),
                            ("revenue", "numeric"), ("unit_price", "numeric")],
                           [["1", "2024-01-01", "EU", "open", "100", "9.5"],
                            ["2", "2024-01-01", "US", "closed", "200", "8.0"],
                            ["3", "2024-01-02", "EU", "open", "150", "7.25"],
                            ["4", "2024-01-02", "US", "pending", "175", "9.0"],
                            ["5", "2024-01-03", "EU", "closed", "120", "8.5"],
                            ["6", "2024-01-03", "US", "open", "190", "7.0"]])
    let mixedRecs = ChartRecommender.recommend(mixed)
    expect(eligible(mixedRecs, mixed), "mixed fixture: every mapping passes ChartRoleEligibility")
    expect(mixedRecs.count >= 5, "mixed fixture: a rich list (\(mixedRecs.count))")
    expect(mixedRecs.first?.config.chartType == .line, "mixed fixture: line first")
    expect(mixedRecs.contains { $0.config.chartType == .scatter }, "mixed fixture: scatter offered")
    expect(mixedRecs.contains { $0.config.chartType == .heatmap }, "mixed fixture: heatmap offered")
    expect(mixedRecs.firstIndex { $0.config.chartType == .bar }! < mixedRecs.firstIndex { $0.config.chartType == .scatter }!,
           "mixed fixture: bar outranks scatter when a dimension exists")
    expect(mixedRecs.contains { $0.config.chartType == .line && $0.config.mappings[.value]?.name == "unit_price" && $0.config.aggregation == .avg },
           "mixed fixture: a line per measure, unit_price averaged")
    var seen = Set<String>()
    let unique = mixedRecs.allSatisfy { r in
        let key = "\(r.config.chartType.rawValue)|\(r.config.mappings.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value.index)" }.joined(separator: ","))"
        return seen.insert(key).inserted
    }
    expect(unique, "mixed fixture: no duplicate (chartType, mappings)")

    // --- Titles and reasons over every fixture ---
    let all = [dailyRecs, regionalRecs, statusRecs, nineRecs, pairRecs, tripleRecs, gridRecs, pairsRecs,
               priceRecs, statusOnly, keyedRecs, textRecs, taskRecs, ratingRecs, productRecs, mixedRecs].flatMap { $0 }
    expect(all.allSatisfy { !$0.title.isEmpty }, "every title is non-empty")
    expect(all.allSatisfy { $0.reason.hasSuffix(".") }, "every reason ends with a period")
    expect(all.allSatisfy { $0.config.display.title.isEmpty && $0.config.display.xAxisTitle.isEmpty && $0.config.display.yAxisTitle.isEmpty },
           "every config leaves chart and axis titles empty")
    let fixtures = [daily, regional, byStatus, nine, pair, triple, grid, pairsOnly, prices, statuses, keyed, textNumbers, tasks, ratings, products, mixed]
    expect(fixtures.allSatisfy { eligible(ChartRecommender.recommend($0), $0) }, "every fixture: every mapping passes eligibility")
    expect(fixtures.allSatisfy { !ChartRecommender.recommend($0).isEmpty }, "every fixture with columns: never empty")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
