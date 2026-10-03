// Standalone test for SQLSummary. Compiled by scripts/test-sql-summary.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

func runTests() {
    let sql = "SELECT\n  timestamp,\n\tuid,\n  orig_h\nFROM conn\nWHERE ts > now() - interval '1 day'"
    expect(SQLSummary.oneLine(sql) == "SELECT timestamp, uid, orig_h FROM conn WHERE ts > now() - interval '1 day'",
           "summary: the whole statement on one line, not only its first line", "got \(SQLSummary.oneLine(sql))")
    expect(SQLSummary.oneLine("\n\n   SELECT   1  \n") == "SELECT 1", "summary: leading blank lines and runs of spaces go")
    expect(SQLSummary.oneLine("") == "", "summary: an empty card shows nothing")
    let long = "SELECT " + Array(repeating: "column_name", count: 40).joined(separator: ", ")
    let cut = SQLSummary.oneLine(long)
    expect(cut.count == SQLSummary.limit + 1 && cut.hasSuffix("…") && long.hasPrefix(String(cut.dropLast())),
           "summary: a long statement stops at the limit with an ellipsis", "got \(cut.count) characters")

    if failures == 0 { print("\nAll SQL summary tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
