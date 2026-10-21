// Standalone test for QueryProgressText — the card header's line while a
// query runs, and the decode of `pharos_query_progress`'s JSON.
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ n: String) {
    if a == b { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)\n  expected: \(b)\n  actual:   \(a)") }
}

func runTests() {
    expectEqual(QueryProgressText.meta(progress: nil, elapsed: 12.7), "Running · 12 s", "no estimate: elapsed only")
    let p = QueryProgress(percentage: 42.9, rowsProcessed: 1_250_000, totalRows: 3_000_000)
    expectEqual(QueryProgressText.meta(progress: p, elapsed: 65), "Running · 42% · 1.2M of 3M rows · 1 min 5 s", "an estimate with rows")
    let noRows = QueryProgress(percentage: 7, rowsProcessed: 0, totalRows: 0)
    expectEqual(QueryProgressText.meta(progress: noRows, elapsed: 3), "Running · 7% · 3 s", "an estimate without row counts")
    let none = QueryProgress(percentage: nil, rowsProcessed: 10, totalRows: 0)
    expectEqual(QueryProgressText.meta(progress: none, elapsed: 0), "Running · 0 s", "DuckDB before its first estimate")
    expectEqual(QueryProgressText.clampedPercentage(QueryProgress(percentage: 140, rowsProcessed: 0, totalRows: 0)), 100, "clamped high")
    expectEqual(QueryProgressText.clampedPercentage(QueryProgress(percentage: .nan, rowsProcessed: 0, totalRows: 0)), nil, "NaN is no estimate")
    let stuck = QueryProgress(percentage: 0, rowsProcessed: 0, totalRows: 400_000_000)
    expectEqual(QueryProgressText.clampedPercentage(stuck), nil, "0% and no rows is no estimate (range())")
    expectEqual(QueryProgressText.meta(progress: stuck, elapsed: 7), "Running · 7 s", "range(): elapsed only, not 0 of 400M")
    expectEqual(QueryProgressText.clampedPercentage(QueryProgress(percentage: 0, rowsProcessed: 5, totalRows: 100)), 0, "0% after real rows is a reading")
    expectEqual(QueryProgressText.compactCount(950), "950", "count: units")
    expectEqual(QueryProgressText.compactCount(1_250), "1.2K", "count: thousands, rounded down")
    expectEqual(QueryProgressText.compactCount(34_000), "34K", "count: whole thousands")
    expectEqual(QueryProgressText.compactCount(250_000_000), "250M", "count: three digits")
    expectEqual(QueryProgressText.compactCount(1_100_000_000), "1.1B", "count: billions")
    expectEqual(QueryProgressText.elapsedText(3725), "1 h 2 min", "elapsed: hours")

    let json = #"{"percentage":12.5,"rowsProcessed":5,"totalRows":40}"#
    let decoded = try? JSONDecoder().decode(QueryProgress.self, from: Data(json.utf8))
    expectEqual(decoded, QueryProgress(percentage: 12.5, rowsProcessed: 5, totalRows: 40), "decodes the core's JSON")
    let nullPct = try? JSONDecoder().decode(QueryProgress.self, from: Data(#"{"percentage":null,"rowsProcessed":0,"totalRows":0}"#.utf8))
    expectEqual(nullPct?.percentage, nil, "a null percentage decodes")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
