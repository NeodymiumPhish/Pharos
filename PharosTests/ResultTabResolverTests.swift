// Standalone test runner for ResultTabResolver. Not part of the app target —
// compiled by scripts/test-result-tab-resolver.sh.
import Foundation

var failures = 0

func expectTrue(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    // Raw editor text carrying a {{var}} token; the substituted value never appears here.
    let rawText = "SELECT * FROM users WHERE id = {{id}};"
    let segments = SQLSegmentParser.parse(rawText)
    expectTrue(segments.count == 1, "one segment parsed")

    let rawSQL = "SELECT * FROM users WHERE id = {{id}}"
    let executedSQL = "SELECT * FROM users WHERE id = 42"

    // Matching on the RAW token-form text succeeds against the raw editor segment.
    let rawOutcome = ResultTabResolver.resolve(sql: rawSQL, previousLineRange: 1...1, in: segments)
    expectTrue(rawOutcome != nil, "raw token-form SQL resolves against raw segment")
    expectTrue(rawOutcome?.segmentIndex == 0, "resolves to segment 0")

    // Matching on the EXECUTED (substituted) text fails — this is exactly the bug the
    // fix avoids by anchoring on rawSQL instead of sql.
    let execOutcome = ResultTabResolver.resolve(sql: executedSQL, previousLineRange: 1...1, in: segments)
    expectTrue(execOutcome == nil, "substituted SQL does NOT resolve against raw segment (regression guard)")

    // No-variable query: raw == executed, resolves as before (backward compatible).
    let plain = SQLSegmentParser.parse("SELECT 1;")
    expectTrue(ResultTabResolver.resolve(sql: "SELECT 1", previousLineRange: 1...1, in: plain) != nil,
               "no-variable query resolves (backward compatible)")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
