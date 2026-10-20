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

    // unavailable: non-select, multi-statement
    expect(SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1]), userSQL: "UPDATE t SET x=1", columns: cols) == nil, "non-SELECT → nil")
    expect(SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1]), userSQL: "SELECT 1; SELECT 2", columns: cols) == nil, "multi-statement → nil")

    // Scatter is now available under push-down: a deterministic, non-aggregating
    // sampled query (not random(), not TABLESAMPLE).
    let sc = SqlPushdownGenerator.generate(cfg(.scatter, [.x: 1, .y: 3]), userSQL: src, columns: cols)
    contains(sc?.sql, #""amt" AS _x"#, "scatter selects x as _x")
    contains(sc?.sql, #""age" AS _y"#, "scatter selects y as _y")
    contains(sc?.sql, "IS NOT NULL", "scatter filters null x/y")
    contains(sc?.sql, "hashtext", "scatter orders by a stable hash (deterministic)")
    expect(sc?.sql.contains("random()") == false, "scatter does NOT use random()")
    contains(sc?.sql, "LIMIT", "scatter caps the sample")
    expect(sc?.layout.kind == .scatter, "scatter layout kind")
    expect(sc?.layout.sampleCap == SqlPushdownGenerator.scatterSampleCap, "scatter carries sampleCap")
    // gantt stays unavailable (never aggregates / samples via push-down).
    expect(SqlPushdownGenerator.generate(cfg(.gantt, [.label: 0, .start: 2, .end: 2]), userSQL: src, columns: cols) == nil, "gantt → nil")
    // scatter still needs both x and y.
    expect(SqlPushdownGenerator.generate(cfg(.scatter, [.x: 1]), userSQL: src, columns: cols) == nil, "scatter without y → nil")
    // non-SELECT scatter still nil.
    expect(SqlPushdownGenerator.generate(cfg(.scatter, [.x: 1, .y: 3]), userSQL: "UPDATE t SET x=1", columns: cols) == nil, "scatter non-SELECT → nil")

    // .auto numeric bucket count → scalar subquery folded into the range CTE.
    let auto = SqlPushdownGenerator.generate(cfg(.bar, [.category: 3, .value: 1], .sum, nb: .auto), userSQL: src, columns: cols)
    contains(auto?.sql, "CEIL(SQRT(", "auto derives ~sqrt(n) buckets")
    contains(auto?.sql, "AS _n", "range CTE projects the resolved bucket count as _n")
    // fixed counts stay literal (no sqrt).
    let fixed = SqlPushdownGenerator.generate(cfg(.bar, [.category: 3, .value: 1], .sum, nb: .b20), userSQL: src, columns: cols)
    expect(fixed?.sql.contains("SQRT") == false, "fixed bin count is literal")
    contains(fixed?.sql, "AS _n", "fixed range CTE also projects _n")

    // Heatmap top-N is now per-axis dense_rank windows, not a flat LIMIT.
    let hm2 = SqlPushdownGenerator.generate(cfg(.heatmap, [.x: 0, .y: 2], .count), userSQL: src, columns: cols)
    contains(hm2?.sql, "dense_rank()", "heatmap ranks per axis")
    contains(hm2?.sql, "_xr", "heatmap x-rank CTE")
    contains(hm2?.sql, "_yr", "heatmap y-rank CTE")
    contains(hm2?.sql, "rk <=", "heatmap keeps top-N per axis")

    // Heatmap numeric X axis → width_bucket + range CTE; layout flags it.
    let hmn = SqlPushdownGenerator.generate(cfg(.heatmap, [.x: 3, .y: 0], .count, nb: .b20), userSQL: src, columns: cols)
    contains(hmn?.sql, "width_bucket", "heatmap numeric axis uses width_bucket")
    contains(hmn?.sql, "_rx", "heatmap x range CTE")
    contains(hmn?.sql, "_xlo", "heatmap x carries lo bound for the builder")
    expect(hmn?.layout.xNumericBinned == true, "layout marks x numeric-binned")
    expect(hmn?.layout.yNumericBinned == false, "y stays discrete")

    // MARK: DuckDB dialect
    func duck(_ c: ChartConfig) -> String? {
        SqlPushdownGenerator.generate(c, userSQL: src, columns: cols, dialect: .duckdb)?.sql
    }
    let duckQueries: [(String, String?)] = [
        ("numeric bins", duck(cfg(.bar, [.category: 3, .value: 1], .sum, nb: .b20))),
        ("auto numeric bins", duck(cfg(.bar, [.category: 3, .value: 1], .sum, nb: .auto))),
        ("monthly timestamptz", duck(cfg(.line, [.category: 2, .value: 1], .sum, tb: .month))),
        ("scatter sample", duck(cfg(.scatter, [.x: 1, .y: 3]))),
        ("numeric heatmap", duck(cfg(.heatmap, [.x: 3, .y: 0], .count, nb: .b10))),
        ("discrete bar", duck(cfg(.bar, [.category: 0, .value: 1], .sum))),
    ]
    for (name, sql) in duckQueries {
        expect(sql != nil, "DuckDB \(name) is generated")
        expect(!(sql ?? "").contains("width_bucket") && !(sql ?? "").contains("hashtext") && !(sql ?? "").contains("AT TIME ZONE"),
               "DuckDB \(name) uses no PostgreSQL-only function")
    }
    contains(duckQueries[2].1, #"date_trunc('month', CAST("ts" AS TIMESTAMP))"#, "DuckDB truncates a TIMESTAMPTZ as UTC with a cast")
    contains(duckQueries[3].1, "ORDER BY hash(_pharos_src)", "DuckDB samples by the row's hash")
    contains(duckQueries[0].1, "floor((", "DuckDB writes width_bucket out")
    // PostgreSQL is unchanged by the new parameter's default.
    contains(SqlPushdownGenerator.generate(cfg(.bar, [.category: 3, .value: 1], .sum, nb: .b20), userSQL: src, columns: cols)?.sql,
             "width_bucket(", "PostgreSQL keeps width_bucket")

    // When the DuckDB CLI is installed, every DuckDB query must RUN. The CLI
    // is a stand-in for the engine Pharos links; set PHAROS_DUCKDB_CLI to
    // choose one, or leave it unset to use `duckdb` on the PATH.
    let cliPath = ProcessInfo.processInfo.environment["PHAROS_DUCKDB_CLI"]
        ?? ["/opt/homebrew/bin/duckdb", "/usr/local/bin/duckdb", NSHomeDirectory() + "/.local/bin/duckdb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    if let cliPath {
        let setup = """
        CREATE TABLE t AS SELECT ['a','b','c'][(range % 3) + 1] AS status, (range * 1.5)::DECIMAL(10,2) AS amt,
          (TIMESTAMP '2024-01-01' + to_hours(range))::TIMESTAMPTZ AS ts, range::INTEGER AS age FROM range(100);
        """
        for (name, sql) in duckQueries {
            guard let sql else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["-csv", "-c", setup + sql + ";"]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try? process.run()
            process.waitUntilExit()
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let rows = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .split(separator: "\n").count
            expect(process.terminationStatus == 0 && errText.isEmpty && rows > 1,
                   "DuckDB \(name) runs in \(cliPath) [\(errText.prefix(200))]")
        }
    } else {
        print("SKIP the DuckDB CLI is not installed; the DuckDB queries were not run")
    }

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
