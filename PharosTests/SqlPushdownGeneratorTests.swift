import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }
func contains(_ hay: String?, _ needle: String, _ n: String) { expect(hay?.contains(needle) == true, n + "  [\(hay ?? "nil")]") }

func runTests() {
    let cols = [ColumnDef(name: "status", dataType: "text"),
                ColumnDef(name: "amt", dataType: "numeric"),
                ColumnDef(name: "ts", dataType: "timestamptz"),
                ColumnDef(name: "age", dataType: "int4")]
    func cfg(_ t: ChartType, _ m: [ChartColumnRole: Int], _ agg: AggregationFn = .sum,
             tb: TemporalBin = .auto, nb: NumericBin = .auto) -> ChartConfig {
        var c = ChartConfig(chartType: t, aggregation: agg, temporalBin: tb); c.numericBin = nb
        for (r, i) in m { c.mappings[r] = ColumnRef(index: i, name: cols[i].name) }
        return c
    }
    let src = "SELECT status, amt, ts, age FROM t"

    // discrete bar, sum
    let bar = SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1], .sum), userSQL: src, columns: cols)
    contains(bar?.sql, #"GROUP BY "status""#, "bar groups by status")
    contains(bar?.sql, #"sum("amt")"#, "bar sum(amt)")
    contains(bar?.sql, "ORDER BY _val DESC", "top-N by value, not alphabetical")
    contains(bar?.sql, "LIMIT", "has LIMIT cap")

    // count needs no value
    let cnt = SqlPushdownGenerator.generate(cfg(.bar, [.category: 0], .count), userSQL: src, columns: cols)
    contains(cnt?.sql, "count(*)", "count(*) with no value mapping")

    // temporal timestamptz → date_trunc AT TIME ZONE UTC
    let ts = SqlPushdownGenerator.generate(cfg(.line, [.category: 2, .value: 1], .sum, tb: .month), userSQL: src, columns: cols)
    contains(ts?.sql, #"date_trunc('month', "ts" AT TIME ZONE 'UTC')"#, "timestamptz binned in UTC")

    // numeric width_bucket with clamp + lo=hi guard
    let num = SqlPushdownGenerator.generate(cfg(.bar, [.category: 3, .value: 1], .sum, nb: .b20), userSQL: src, columns: cols)
    contains(num?.sql, "width_bucket", "numeric uses width_bucket")
    contains(num?.sql, "LEAST(", "width_bucket clamped with LEAST")
    contains(num?.sql, "_r.lo = _r.hi", "single-bucket lo=hi guard")

    // series: _series column present, layout.hasSeries true
    let ser = SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1, .series: 2], .sum), userSQL: src, columns: cols)
    contains(ser?.sql, "AS _series", "series emits _series column")
    expect(ser?.layout.hasSeries == true, "series layout.hasSeries true")

    // numeric-bin + series: series dropped, no _series, layout.hasSeries false
    let ns = SqlPushdownGenerator.generate(cfg(.bar, [.category: 3, .value: 1, .series: 0], .sum, nb: .b20), userSQL: src, columns: cols)
    expect(ns?.sql.contains("_series") == false, "numeric-bin drops series (no _series in SQL)")
    expect(ns?.layout.hasSeries == false, "numeric-bin layout.hasSeries false (matches SQL)")
    contains(ns?.sql, "ORDER BY _bucket", "numeric bins ordered by bucket, not _val")

    // non-count aggregation with no value mapping → unavailable (nil), not count(*)
    expect(SqlPushdownGenerator.generate(cfg(.bar, [.category: 0], .sum), userSQL: src, columns: cols) == nil, "sum without value → nil")

    // time-of-day temporal column is NOT date_trunc'd (would error); treated discrete
    let tcols = cols + [ColumnDef(name: "tod", dataType: "time")]
    var todCfg = ChartConfig(chartType: .bar, aggregation: .sum, temporalBin: .hour)
    todCfg.mappings[.category] = ColumnRef(index: 4, name: "tod")
    todCfg.mappings[.value] = ColumnRef(index: 1, name: "amt")
    let tod = SqlPushdownGenerator.generate(todCfg, userSQL: "SELECT 1", columns: tcols)
    expect(tod?.sql.contains("date_trunc") == false, "time column not date_trunc'd")

    // heatmap groups by x,y
    let hm = SqlPushdownGenerator.generate(cfg(.heatmap, [.x: 0, .y: 2], .count), userSQL: src, columns: cols)
    contains(hm?.sql, "GROUP BY", "heatmap groups")
    contains(hm?.sql, "_x", "heatmap x alias")

    // identifier with a quote is escaped
    let weird = [ColumnDef(name: #"a"b"#, dataType: "text"), ColumnDef(name: "v", dataType: "numeric")]
    let esc = SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1]), userSQL: "SELECT 1", columns: weird)
    contains(esc?.sql, #""a""b""#, "identifier quote doubled")

    // unavailable: scatter, non-select, multi-statement
    expect(SqlPushdownGenerator.generate(cfg(.scatter, [.x: 1, .y: 3]), userSQL: src, columns: cols) == nil, "scatter → nil")
    expect(SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1]), userSQL: "UPDATE t SET x=1", columns: cols) == nil, "non-SELECT → nil")
    expect(SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1]), userSQL: "SELECT 1; SELECT 2", columns: cols) == nil, "multi-statement → nil")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
