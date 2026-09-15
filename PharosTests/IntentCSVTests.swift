// Standalone test for the CSV an App Intent hands back. Compiled by
// scripts/test-intent-csv.sh.
//
// What this suite is FOR: the ESCAPING is `ResultsCopyExport.csvText`, already
// covered where the grid uses it. What is new here is the mapping from a
// `QueryResult` to a `CopyData` — and that mapping is where the one distinction
// that matters can be lost. A SQL NULL must reach `CopyData` as `nil` and an
// empty string as `""`; collapse them and an automation reads a missing value
// and an empty text value as the same thing, with nothing on screen to notice
// it by. Every value of a real result arrives as a JSON string, so the rows are
// built the way the FFI delivers them.
import AppKit

var failures = 0

private func expect(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)") }
}

// MARK: - Fixtures

private func result(_ names: [String], _ rows: [[Any?]]) -> QueryResult {
    QueryResult(
        columns: names.map { ColumnDef(name: $0, dataType: "text") },
        rows: rows.map { $0.map { AnyCodable($0) } },
        rowCount: rows.count,
        executionTimeMs: 1,
        hasMore: false,
        historyEntryId: nil
    )
}

// MARK: - Tests

func runTests() {
    // 1. The header row is the column names, and the rows follow in order.
    expect(
        IntentResultCSV.csv(from: result(["id", "name"], [["1", "alice"], ["2", "bob"]])),
        "id,name\n1,alice\n2,bob",
        "header row then data rows"
    )

    // 2. Commas, quotes and newlines are quoted RFC 4180 style — in the header
    //    as well as the body. A column named by an expression really does hold
    //    spaces and punctuation.
    expect(
        IntentResultCSV.csv(from: result(
            ["first, last", "note"],
            [["a,b", "she said \"hi\""], ["line\nbreak", "plain"]]
        )),
        "\"first, last\",note\n\"a,b\",\"she said \"\"hi\"\"\"\n\"line\nbreak\",plain",
        "commas, quotes and newlines are quoted"
    )

    // 3. THE ONE THAT MATTERS: a SQL NULL is an empty field, and so is an empty
    //    string — but they must travel as `nil` and `""` respectively, not both
    //    as `""`. Asserted on the CopyData, because the CSV text renders the two
    //    identically and so cannot tell them apart.
    let mixed = IntentResultCSV.copyData(from: result(["a", "b"], [[nil, ""]]))
    expect(mixed.rows[0][0] == nil ? "nil" : "notnil", "nil", "SQL NULL reaches CopyData as nil")
    expect(mixed.rows[0][1] ?? "nil", "", "an empty string stays an empty string")

    // 4. A result with no rows is still the header line — an automation that
    //    counts lines must not see a query that returned nothing as a failure.
    expect(
        IntentResultCSV.csv(from: result(["only"], [])),
        "only",
        "no rows still writes the header"
    )

    // 5. Unicode passes through untouched: no escaping, no normalisation, and
    //    the bytes an analyst pastes onward are the bytes the database held.
    expect(
        IntentResultCSV.csv(from: result(["名前"], [["Ωmega — café"], ["🛰 satellite"]])),
        "名前\nΩmega — café\n🛰 satellite",
        "unicode is untouched"
    )

    // 6. The filename is built from the query's name, which is user text.
    expect(IntentResultCSV.sanitizedFilename("Monthly revenue"), "Monthly revenue", "plain name kept")
    expect(IntentResultCSV.sanitizedFilename("a/b:c\\d"), "a-b-c-d", "separators replaced")
    expect(IntentResultCSV.sanitizedFilename("   "), "Query", "blank name falls back")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)
}
