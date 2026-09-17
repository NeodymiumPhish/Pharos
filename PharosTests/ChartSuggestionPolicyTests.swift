// Standalone test runner for ChartSuggestionPolicy — the prompt and the
// validation of the model's answer, without FoundationModels.
// Compiled by scripts/test-chart-suggestion-policy.sh.
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func makeResult(_ columns: [(String, String)], _ rows: [[String?]]) -> QueryResult {
    let cols = columns.map { ColumnDef(name: $0.0, dataType: $0.1) }
    let anyRows = rows.map { row in row.map { AnyCodable($0 as Any?) } }
    return QueryResult(columns: cols, rows: anyRows, rowCount: rows.count,
                       executionTimeMs: 0, hasMore: false, historyEntryId: nil)
}

typealias Policy = ChartSuggestionPolicy

func answer(_ type: String, x: String, y: String? = nil, group: String? = nil, agg: String? = "sum",
            bucket: String? = nil, title: String = "T", xt: String = "X", yt: String = "Y", reason: String = "Because") -> Policy.Answer {
    Policy.Answer(chartType: type, xColumn: x, yColumn: y, groupColumn: group, aggregation: agg,
                  timeBucket: bucket, title: title, xAxisTitle: xt, yAxisTitle: yt, reason: reason)
}

func runTests() {
    let sales = makeResult([("order_id", "integer"), ("ordered_at", "timestamptz"), ("region", "text"),
                            ("revenue", "numeric"), ("shipped_at", "timestamptz")],
                           [["1", "2024-01-01 00:00:00+00", "north", "10.5", "2024-01-03 00:00:00+00"],
                            ["2", "2024-02-01 00:00:00+00", "south", "20", "2024-02-02 00:00:00+00"],
                            ["3", "2024-03-01 00:00:00+00", "north", "7", "2024-03-05 00:00:00+00"]])
    let profiles = ColumnProfiler.profile(sales)
    let candidates = ChartRecommender.recommend(profiles: profiles, columns: sales.columns)

    // --- prompt ---
    let prompt = Policy.prompt(profiles: profiles, rowCount: 3, candidates: candidates, sql: "SELECT * FROM orders")
    expect(prompt.hasPrefix("Recommend the best chart"), "prompt opens with the task")
    expect(prompt.contains("Rows: 3."), "prompt states the row count")
    expect(prompt.contains("- order_id (integer): identifier, 3 distinct, unique"), "identifier column line")
    expect(prompt.contains("- ordered_at (timestamptz): time, 3 distinct, unique, spans 60 days"), "time column line with span")
    expect(prompt.contains("- region (text): category, 2 distinct"), "category column line")
    expect(prompt.contains("- revenue (numeric): measure, 3 distinct, unique, non-negative, decimals"), "measure column line")
    expect(prompt.contains("Candidates, best first:\n1. "), "candidates are numbered from 1")
    expect(prompt.contains("SQL:\nSELECT * FROM orders"), "the SQL follows")
    expect(!prompt.contains("north") && !prompt.contains("10.5"), "no cell value reaches the prompt")
    expect(prompt.contains("column names for each role") == false, "no stray wording")

    // null share, negatives, integers
    let mixed = makeResult([("delta", "integer"), ("note", "text")],
                           [["-1", "a"], ["2", nil], ["3", nil], ["4", "b"]])
    let mp = ColumnProfiler.profile(mixed)
    expect(Policy.describe(mp[0]) == "delta (integer): measure, 4 distinct, unique, has negatives, integers", "negatives and integers described")
    expect(Policy.describe(mp[1]) == "note (text): category, 2 distinct, unique, 50% null", "null share described")

    // span text
    expect(Policy.spanText(1800) == "under an hour" && Policy.spanText(7200) == "2 hours", "span: hours")
    expect(Policy.spanText(86_400 * 10) == "10 days" && Policy.spanText(86_400 * 365 * 3) == "3 years", "span: days and years")

    // caps
    let long = String(repeating: "x", count: 2500)
    expect(Policy.cappedSQL(long).hasSuffix(Policy.truncationMarker) && Policy.cappedSQL(long).count == 2000 + Policy.truncationMarker.count, "SQL capped with a marker")
    let many = makeResult((0..<45).map { ("c\($0)", "text") }, [])
    let manyPrompt = Policy.prompt(profiles: ColumnProfiler.profile(many), rowCount: 0, candidates: [], sql: "")
    expect(manyPrompt.contains("- c39 (text)") && !manyPrompt.contains("- c40 (text)") && manyPrompt.contains("and 5 more columns"), "column list capped at 40")
    expect(!manyPrompt.contains("SQL:") && !manyPrompt.contains("Candidates"), "empty SQL and candidates are omitted")

    // --- apply: happy paths ---
    let line = try! Policy.apply(answer("line", x: "ordered_at", y: "revenue", group: "region", bucket: "month",
                                        title: "Revenue by month", xt: "Month", yt: "Revenue", reason: "trend"), profiles: profiles)
    expect(line.chartType == .line, "line: type")
    expect(line.mappings[.category] == ColumnRef(index: 1, name: "ordered_at"), "line: category from xColumn")
    expect(line.mappings[.value] == ColumnRef(index: 3, name: "revenue"), "line: value from yColumn")
    expect(line.mappings[.series] == ColumnRef(index: 2, name: "region"), "line: series from groupColumn")
    expect(line.temporalBin == .month, "line: time bucket")
    expect(line.display.title == "Revenue by month" && line.display.xAxisTitle == "Month" && line.display.yAxisTitle == "Revenue", "line: titles")

    let bar = try! Policy.apply(answer("Bar", x: "Region", y: "\"revenue\"", agg: "avg"), profiles: profiles)
    expect(bar.chartType == .bar && bar.aggregation == .avg, "bar: case-insensitive type, avg")
    expect(bar.mappings[.category]?.name == "region" && bar.mappings[.value]?.name == "revenue", "bar: case-insensitive and quoted names resolve")
    expect(bar.display.sort == .valueDesc, "bar over a category sorts by value")

    let count = try! Policy.apply(answer("bar", x: "region", y: nil, agg: "count"), profiles: profiles)
    expect(count.aggregation == .count && count.mappings[.value] == nil, "count bar needs no value")

    let scatter = try! Policy.apply(answer("scatter", x: "order_id", y: "revenue", group: "revenue", agg: nil), profiles: profiles)
    expect(scatter.mappings[.x]?.name == "order_id" && scatter.mappings[.y]?.name == "revenue" && scatter.mappings[.size]?.name == "revenue", "scatter: x, y, size")
    expect(scatter.aggregation == .sum, "missing aggregation defaults to sum")

    let heat = try! Policy.apply(answer("heatmap", x: "region", y: nil, group: "ordered_at"), profiles: profiles)
    expect(heat.mappings[.x]?.name == "region" && heat.mappings[.y]?.name == "ordered_at" && heat.mappings[.value] == nil, "heatmap: x, y from group")
    expect(heat.aggregation == .count, "heatmap without a value counts")

    let gantt = try! Policy.apply(answer("gantt", x: "region", y: "ordered_at", group: "shipped_at"), profiles: profiles)
    expect(gantt.mappings[.label]?.name == "region" && gantt.mappings[.start]?.name == "ordered_at" && gantt.mappings[.end]?.name == "shipped_at", "gantt: label, start, end")

    let pie = try! Policy.apply(answer("pie", x: "region", y: "revenue", group: "region"), profiles: profiles)
    expect(pie.mappings[.series] == nil, "pie ignores a group column")

    // --- apply: rejections ---
    func rejects(_ a: Policy.Answer, _ expected: Policy.Rejection, _ name: String) {
        do { _ = try Policy.apply(a, profiles: profiles); expect(false, name) }
        catch let r as Policy.Rejection { expect(r == expected, name) }
        catch { expect(false, name) }
    }
    rejects(answer("bubble", x: "region", y: "revenue"), .unknownChartType("bubble"), "unknown chart type rejected")
    rejects(answer("bar", x: "shop", y: "revenue"), .unknownColumn("shop"), "unknown column rejected")
    rejects(answer("bar", x: "region", y: "ordered_at"), .roleRefusesColumn(.value, "ordered_at"), "a time column is refused as the value")
    rejects(answer("bar", x: "region", y: nil, agg: "sum"), .missingColumn(.value), "sum without a value rejected")
    rejects(answer("scatter", x: "revenue", y: nil, agg: nil), .missingColumn(.y), "scatter without y rejected")
    rejects(answer("gantt", x: "region", y: "ordered_at", group: nil), .missingColumn(.end), "gantt without end rejected")
    rejects(answer("heatmap", x: "region", y: "revenue", group: nil), .missingColumn(.y), "heatmap without y rejected")
    rejects(answer("scatter", x: "region", y: "revenue"), .roleRefusesColumn(.x, "region"), "scatter x refuses a text column")

    // a text column of numbers is accepted as a measure (refined kind)
    let texty = ColumnProfiler.profile(makeResult([("k", "text"), ("amount", "text")], [["a", "1.5"], ["b", "2"]]))
    let refined = try! Policy.apply(answer("bar", x: "k", y: "amount"), profiles: texty)
    expect(refined.mappings[.value]?.name == "amount", "refined numeric text accepted as value")

    // --- titles and reason ---
    expect(Policy.label("  \"Revenue by Month.\"  ", cap: 60) == "Revenue by Month", "title: quotes, stop and space trimmed")
    expect(Policy.label("safe\u{202E}gpj.exe", cap: 60) == "safegpj.exe", "title: bidi override removed")
    let longTitle = Policy.label(String(repeating: "word ", count: 30), cap: 60)
    expect(longTitle.count <= 61 && longTitle.hasSuffix("\u{2026}"), "title capped with an ellipsis")
    expect(Policy.reason("revenue  grows\nover time") == "revenue grows over time.", "reason: single-spaced with a full stop")
    expect(Policy.reason("Done!") == "Done!" && Policy.reason("   ") == "", "reason: keeps its own stop; empty stays empty")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
