// Standalone runner for TagDraft — capture rules and the modal's live count.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private let columns = [
    ColumnDef(name: "md5", dataType: "text"),
    ColumnDef(name: "ip", dataType: "inet"),
    ColumnDef(name: "port", dataType: "int4"),
]

func runTests() {
    let rows: [[String?]] = [
        ["D41D8C", "10.2.3.4/32", "443"],
        ["AABBCC", "10.9.9.9", "443"],
        ["D41D8C", "10.2.3.4", "8443"],   // same md5 and ip as row 0 once normalized
        [nil, "10.4.4.4", "443"],
    ]

    // 1. One tuple per selected row, of exactly the checked columns.
    let single = TagDraft.tuples(selectedRows: [rows[0], rows[1]], columns: columns,
                                 checkedColumns: [0], originConnection: "c1",
                                 originTable: "public.certs")
    expectEqual(single.count, 2, "two rows give two tuples")
    expectEqual(single[0].conditions.count, 1, "one checked column gives one value")
    expectEqual(single[0].conditions[0].column, "md5", "the column travels as provenance")
    expectEqual(single[0].conditions[0].display, "D41D8C", "display keeps the captured text")
    expectEqual(single[0].conditions[0].value, "d41d8c", "value is normalized")
    expectEqual(single[0].originTable, "public.certs", "origin travels with the tuple")

    // 2. Two checked columns give one two-value tuple per row — NOT a cross
    //    product. The tuple is the row's finding.
    let pair = TagDraft.tuples(selectedRows: [rows[0], rows[1]], columns: columns,
                               checkedColumns: [0, 1], originConnection: "c1",
                               originTable: "public.certs")
    expectEqual(pair.count, 2, "two rows, two tuples")
    expectEqual(pair[0].conditions.count, 2, "two checked columns give two values")

    // 3. Rows that normalize to the same tuple collapse. The unique index would
    //    absorb the repeat anyway; collapsing here keeps the live count honest
    //    about what will actually be saved.
    let collapsed = TagDraft.tuples(selectedRows: [rows[0], rows[2]], columns: columns,
                                    checkedColumns: [0, 1], originConnection: "c1",
                                    originTable: "public.certs")
    expectEqual(collapsed.count, 1, "10.2.3.4/32 and 10.2.3.4 are one tuple")

    // 4. A NULL drops out of its tuple; a tuple that loses everything
    //    contributes nothing at all.
    let withNull = TagDraft.tuples(selectedRows: [rows[3]], columns: columns,
                                   checkedColumns: [0, 1], originConnection: "c1",
                                   originTable: "public.certs")
    expectEqual(withNull.count, 1, "a partly NULL row still contributes")
    expectEqual(withNull[0].conditions.count, 1, "the NULL value is dropped")
    let allNull = TagDraft.tuples(selectedRows: [[nil, nil, nil]], columns: columns,
                                  checkedColumns: [0, 1], originConnection: "c1",
                                  originTable: "public.certs")
    expectEqual(allNull.isEmpty, true, "an all-NULL row contributes nothing")

    // 5. Nothing checked, nothing captured — the modal disables Create on this.
    expectEqual(TagDraft.tuples(selectedRows: rows, columns: columns, checkedColumns: [],
                                originConnection: "c1", originTable: "t").isEmpty,
                true, "no checked column, no tuples")

    // 6. An out-of-range column index is ignored rather than trapping: the
    //    checkbox list and the result could in principle disagree after a
    //    Load More that changed the shape.
    expectEqual(TagDraft.tuples(selectedRows: [rows[0]], columns: columns,
                                checkedColumns: [0, 99], originConnection: "c1",
                                originTable: "t")[0].conditions.count,
                1, "an unknown column index is skipped")

    // 7. The live count runs the real matcher over the loaded rows.
    let draft = TagDraft.previewTag(tuples: single)
    expectEqual(TagRuleMatcher.matchCount(tag: draft, columns: columns, rows: rows), 3,
                "two md5 values match three loaded rows")
    expectEqual(TagDraft.isBroad(matched: 3, loaded: 4), true, "3 of 4 is over a tenth")
    expectEqual(TagDraft.isBroad(matched: 3, loaded: 100), false, "3 of 100 is not")
    expectEqual(TagDraft.isBroad(matched: 0, loaded: 0), false, "no rows, no warning")

    // Exactly a tenth is NOT broad. The design says the warning appears ABOVE
    // 10%, so the boundary belongs to the quiet side — and `>` versus `>=` is
    // invisible to every other case here.
    expectEqual(TagDraft.isBroad(matched: 1, loaded: 10), false, "exactly a tenth is not broad")
    expectEqual(TagDraft.isBroad(matched: 2, loaded: 10), true, "just over a tenth is broad")

    print(failures == 0 ? "\nAll TagDraft checks passed" : "\n\(failures) FAILED")
    if failures > 0 { exit(1) }
}
