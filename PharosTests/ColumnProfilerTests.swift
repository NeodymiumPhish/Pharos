// Standalone test runner for ColumnProfiler + ChartRoleEligibility.
// Compiled by scripts/test-column-profiler.sh.
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

func runTests() {
    // --- kinds, counts, shares ---
    let r = makeResult([("order_id", "integer"), ("region", "text"), ("revenue", "numeric"),
                        ("ordered_at", "timestamptz"), ("amount", "text"), ("paid", "boolean"),
                        ("when", "text"), ("delta", "numeric")],
                       [["1", "north", "10.5", "2024-01-01 00:00:00+00", "1.5", "t", "2024-01-01", "-1"],
                        ["2", "south", "20", "2024-01-02 00:00:00+00", "2", "f", "2024-02-01", "2"],
                        ["3", "north", nil, "2024-01-03 00:00:00+00", "3", "t", "2024-03-01", "3"],
                        ["4", nil, "5", "2024-01-05 12:00:00+00", "4", nil, "2024-04-01", "4"]])
    let p = ColumnProfiler.profile(r)
    expect(p.count == 8, "one profile per column")
    let id = p[0], region = p[1], revenue = p[2], at = p[3], amount = p[4], paid = p[5], when = p[6], delta = p[7]

    expect(id.kind == .numeric && id.looksLikeIdentifier, "order_id: numeric identifier by name")
    expect(id.isUnique, "order_id: unique")
    expect(!id.isMeasure, "order_id: never a measure")
    expect(id.allIntegers, "order_id: integers")

    expect(region.kind == .categorical && region.isDimension, "region: categorical dimension")
    expect(region.distinctCount == 2 && region.nonNullCount == 3, "region: 2 distinct of 3 non-null")
    expect(abs(region.nullShare - 0.25) < 0.001, "region: null share 25%")
    expect(!region.isUnique, "region: not unique")

    expect(revenue.isMeasure, "revenue: measure")
    expect(revenue.allNonNegative && !revenue.allIntegers, "revenue: non-negative decimals")
    expect(revenue.nonNullCount == 3, "revenue: null skipped")

    expect(at.kind == .temporal, "ordered_at: temporal")
    expect(at.spanSeconds == 4.5 * 86_400, "ordered_at: span is 4.5 days")

    expect(amount.declaredKind == .categorical && amount.kind == .numeric, "amount: text of numbers refined to numeric")
    expect(amount.isMeasure, "amount: refined numeric is a measure")

    expect(paid.isBoolean && paid.isDimension && !paid.isMeasure, "paid: boolean is a dimension")
    expect(when.declaredKind == .categorical && when.kind == .temporal, "when: text of dates refined to temporal")
    expect(when.spanSeconds == 91 * 86_400, "when: span across the four dates")
    expect(delta.isMeasure && !delta.allNonNegative, "delta: measure with a negative")

    // --- identifier names ---
    func idName(_ n: String, _ t: String = "text") -> Bool {
        ColumnProfiler.profile(makeResult([(n, t)], [["a"], ["b"]]))[0].looksLikeIdentifier
    }
    expect(idName("id") && idName("customer_id") && idName("customerId") && idName("uuid") && idName("row_key"), "identifier names")
    expect(idName("token", "uuid"), "uuid type is an identifier")
    expect(!idName("paid") && !idName("valid") && !idName("Kind"), "paid/valid/Kind are not identifiers")

    // --- low-cardinality numeric is a dimension, high-cardinality is not ---
    let rating = ColumnProfiler.profile(makeResult([("rating", "integer")], (0..<40).map { [String($0 % 5 + 1)] }))[0]
    expect(rating.isDimension && rating.isMeasure, "rating: few distinct integers can be a dimension and a measure")
    let price = ColumnProfiler.profile(makeResult([("price", "numeric")], (0..<40).map { [String(Double($0) * 1.5)] }))[0]
    expect(!price.isDimension && price.isMeasure, "price: many distinct values is a measure only")

    // --- sample limit ---
    let big = makeResult([("n", "integer")], (0..<3000).map { [String($0)] })
    let bp = ColumnProfiler.profile(big)[0]
    expect(bp.sampledRows == 2000 && bp.distinctCount == 2000, "profile reads the first 2000 rows")
    expect(ColumnProfiler.profile(big, sampleLimit: 10)[0].sampledRows == 10, "sample limit is a parameter")

    // --- empty result ---
    let empty = makeResult([("x", "text")], [])
    let ep = ColumnProfiler.profile(empty)[0]
    expect(ep.nonNullCount == 0 && ep.nullShare == 0 && !ep.isUnique && ep.kind == .categorical, "empty column: zeros, declared kind")

    // --- eligibility table ---
    expect(ChartRoleEligibility.roles(for: .pie) == [.category, .value], "pie has no series role")
    expect(ChartRoleEligibility.roles(for: .bar) == [.category, .value, .series], "bar roles")
    expect(ChartRoleEligibility.roles(for: .scatter) == [.x, .y, .size], "scatter roles")
    expect(ChartRoleEligibility.accepts(.value, kind: .numeric, chartType: .bar), "value takes numeric")
    expect(!ChartRoleEligibility.accepts(.value, kind: .temporal, chartType: .bar), "value refuses temporal")
    expect(ChartRoleEligibility.accepts(.x, kind: .temporal, chartType: .scatter), "scatter x takes temporal")
    expect(!ChartRoleEligibility.accepts(.y, kind: .categorical, chartType: .scatter), "scatter y refuses text")
    expect(ChartRoleEligibility.accepts(.x, kind: .categorical, chartType: .heatmap), "heatmap x takes anything")
    expect(ChartRoleEligibility.accepts(.start, kind: .numeric, chartType: .gantt), "gantt start takes numeric")
    expect(ChartRoleEligibility.accepts(.series, kind: .numeric, chartType: .line), "series takes anything")
    expect(ChartRoleEligibility.usesAggregation(.heatmap) && !ChartRoleEligibility.usesAggregation(.scatter), "aggregation applies to heatmap not scatter")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
