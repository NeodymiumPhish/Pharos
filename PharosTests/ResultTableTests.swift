// Standalone runner for ResultTable — the columnar PRB1 block, its builder and
// its JSON form. Compiled by scripts/test-result-table.sh.
import Foundation

var failures = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectThrows(_ name: String, _ body: () throws -> Void) {
    do { try body(); failures += 1; print("FAIL \(name): did not throw") } catch { print("PASS \(name)") }
}

func runTests() {
    let rows: [[String?]] = [
        ["1", "alpha", nil, ""],
        ["2", nil, "ünïcødé ✓ 🐘", "x"],
        ["3", "a\u{0}b", "\t\n", nil],
    ]
    let table = ResultTable(rows: rows)

    // MARK: Cells

    expect(table.rowCount, 3, "row count")
    expect(table.columnCount, 4, "column count")
    expect(table.allRows, rows, "every cell reads back")
    expect(table.isNull(0, 2), true, "NULL is NULL")
    expect(table.isNull(0, 3), false, "an empty string is not NULL")
    expect(table.string(0, 3), "", "an empty string reads as empty")
    expect(table.displayString(0, 2), "", "displayString of NULL is empty")
    expect(table.string(1, 2), "ünïcødé ✓ 🐘", "multibyte UTF-8")
    expect(table.string(2, 1), "a\u{0}b", "an interior NUL byte survives")
    expect(table.utf8Count(1, 2), "ünïcødé ✓ 🐘".utf8.count, "utf8Count")
    expect(table.withUTF8(0, 1) { Array($0) }, Array("alpha".utf8), "withUTF8 bytes")
    expect(table.withUTF8(0, 2) { _ in 1 } == nil, true, "withUTF8 of NULL is nil")
    expect(table.string(0, 9), nil, "a column past the last reads as NULL")
    expect(table.isNull(0, 9), true, "a column past the last is NULL")
    expect(table[1, 0], "2", "subscript")
    expect(table.row(1), rows[1], "one row")

    // MARK: Ragged input

    let ragged = ResultTable(rows: [["a", "b", "c"], ["d"]])
    expect(ragged.columnCount, 3, "the widest row sets the column count")
    expect(ragged.row(1), ["d", nil, nil], "a short row's missing cells are NULL")

    // MARK: Empty tables

    let empty = ResultTable(rows: [])
    expect(empty.rowCount, 0, "no rows")
    expect(empty.columnCount, 0, "no columns")
    expect(ResultTable(columnCount: 5).columnCount, 5, "an empty table keeps its column count")
    expect(ResultTable(rows: [[], []]).rowCount, 2, "rows with zero columns")

    // MARK: Block round trip

    let reread = try! ResultTable(block: table.block)
    expect(reread, table, "a block reads back as the same table")
    expect(reread.allRows, rows, "a block reads back cell for cell")
    expect(table.byteCount, table.block.count, "byteCount is the block size")

    // Padding edges: text lengths 0...9 and row counts 0...17 (bitmaps 0...3 bytes).
    for n in 0...17 {
        let r = (0..<n).map { i -> [String?] in [String(repeating: "x", count: i % 10), i % 3 == 0 ? nil : "y"] }
        let t = ResultTable(rows: r)
        let back = try! ResultTable(block: t.block)
        if back.allRows != r { failures += 1; print("FAIL padding round trip at \(n) rows") }
    }
    print("PASS padding round trips, 0...17 rows")

    // MARK: The reference block — the same bytes pharos-core pins
    // (`commands::result_block::tests::the_reference_block_bytes`).

    func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    let referenceBytes: [UInt8] = Array("PRB1".utf8) + le(1) + le(2) + le(2)
        + le(2) + [0, 0, 0, 0] + le(0) + le(2) + le(2) + [0x61, 0x62, 0, 0]
        + le(2) + [1, 0, 0, 0] + le(0) + le(0) + le(2) + [0xC3, 0xA9, 0, 0]
    let referenceTable = ResultTable(rows: [["ab", nil], ["", "é"]])
    expect([UInt8](referenceTable.block), referenceBytes, "the builder writes the reference block")
    expect(try! ResultTable(block: Data(referenceBytes)).allRows, [["ab", nil], ["", "é"]],
           "the reference block reads back")

    // MARK: Bad blocks throw, never trap

    var bytes = [UInt8](table.block)
    expectThrows("an empty block") { _ = try ResultTable(block: Data()) }
    expectThrows("a wrong magic") { var b = bytes; b[0] = 0x58; _ = try ResultTable(block: Data(b)) }
    expectThrows("a wrong version") { var b = bytes; b[4] = 2; _ = try ResultTable(block: Data(b)) }
    expectThrows("a cut-short block") { _ = try ResultTable(block: Data(bytes.dropLast(4))) }
    expectThrows("bytes after the end") { _ = try ResultTable(block: Data(bytes + [0, 0, 0, 0])) }
    // The first column's offsets start after header (16) + byteLength (4) + bitmap (4, padded).
    expectThrows("offsets out of order") { var b = bytes; b[16 + 4 + 4 + 4] = 0xFF; _ = try ResultTable(block: Data(b)) }
    expectThrows("a row count larger than the data") { var b = bytes; b[8] = 200; _ = try ResultTable(block: Data(b)) }
    bytes[0] = bytes[0]   // keep `bytes` mutable for the copies above

    // MARK: Appending and gathering equal a rebuilt table

    let more: [[String?]] = [["4", "delta", "δ", nil], ["5", nil, nil, "z"]]
    let page = ResultTable(rows: more)
    expect(table.appending(page), ResultTable(rows: rows + more), "appending = one table of all rows")
    expect(table.appending(page).allRows, rows + more, "appending cell for cell")
    expect(ResultTable(columnCount: 0).appending(page), page, "an empty table appended to takes the page")
    expect(table.appending(ResultTable(columnCount: 4)), table, "appending no rows changes nothing")
    expect(table.gathering(rows: [2, 0]), ResultTable(rows: [rows[2], rows[0]]), "gathering in order")
    expect(table.gathering(rows: []).rowCount, 0, "gathering nothing")
    expect(table.slice(1..<3), ResultTable(rows: Array(rows[1..<3])), "slice")
    let threePages = ResultTable(rows: [rows[0]]).appending(ResultTable(rows: [rows[1]])).appending(ResultTable(rows: [rows[2]]))
    expect(threePages, table, "three appended pages = one table")

    // MARK: JSON, the stored shape

    let json = try! JSONEncoder().encode(table)
    let reference = try! JSONEncoder().encode(rows)
    expect(String(data: json, encoding: .utf8), String(data: reference, encoding: .utf8),
           "encodes exactly as [[String?]]")
    expect(try! JSONDecoder().decode(ResultTable.self, from: reference), table, "decodes [[String?]]")
    expect(try! JSONDecoder().decode(ResultTable.self, from: Data("[]".utf8)).rowCount, 0, "decodes []")
    expect(try! JSONDecoder().decode(ResultTable.self, from: Data(#"[["a","b"],["c"]]"#.utf8)).row(1), ["c", nil],
           "a short JSON row is padded with NULL")
    expectThrows("a longer JSON row than the first") {
        _ = try JSONDecoder().decode(ResultTable.self, from: Data(#"[["a"],["b","c"]]"#.utf8))
    }
    expectThrows("a number cell is refused (every real cell is text)") {
        _ = try JSONDecoder().decode(ResultTable.self, from: Data(#"[[1]]"#.utf8))
    }

    // MARK: A wrapped block is freed when its table goes
    // This runs with no autorelease pool, like pharos-core's worker threads,
    // where the FFI's blocks are wrapped. `-bytes` autoreleases; without the
    // storage's own pool the deallocator never ran and every block leaked.

    var freed = false
    do {
        let bytes = [UInt8](ResultTable(rows: [["leak", nil]]).block)
        let raw = malloc(bytes.count)!.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeBytes { raw.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count) }
        let wrapped = try! ResultTable(block: Data(bytesNoCopy: raw, count: bytes.count,
                                                   deallocator: .custom { p, _ in free(p); freed = true }))
        _ = wrapped.string(0, 0)
        _ = wrapped.block.count
    }
    expect(freed, true, "a block's deallocator runs when its table goes, outside any autorelease pool")

    // MARK: Spill to a mapped file

    let spillDir = FileManager.default.temporaryDirectory.appendingPathComponent("result-table-spill-\(getpid())")
    let spilled = try! table.spilled(to: spillDir)
    expect(spilled, table, "a spilled table has the same cells")
    expect(spilled.allRows, rows, "a spilled table reads back cell for cell")
    expect(spilled.isSpilled, true, "a spilled table says so")
    expect(table.isSpilled, false, "an in-memory table does not")
    let left = (try? FileManager.default.contentsOfDirectory(atPath: spillDir.path)) ?? []
    expect(left, [], "no spill file name is left behind")
    expect(spilled.appending(page).isSpilled, false, "a table built from a spilled one is in memory")
    try? FileManager.default.removeItem(at: spillDir)

    // MARK: Size and speed (information only)

    if ProcessInfo.processInfo.environment["TABLE_BENCH"] == "1" {
        var cells: [[String?]] = []
        cells.reserveCapacity(200_000)
        for i in 0..<200_000 {
            cells.append((0..<20).map { c -> String? in
                c == 3 ? nil : c % 2 == 0 ? String(i * 31 + c) : "value \(i) in column \(c) with some text"
            })
        }
        let start = DispatchTime.now()
        let jsonData = try! JSONEncoder().encode(cells)
        let decodeStart = DispatchTime.now()
        let big = try! JSONDecoder().decode(ResultTable.self, from: jsonData)
        let end = DispatchTime.now()
        func ms(_ a: DispatchTime, _ b: DispatchTime) -> Int { Int((b.uptimeNanoseconds - a.uptimeNanoseconds) / 1_000_000) }
        print("BENCH 200k x 20: JSON \(jsonData.count / 1_000_000) MB, block \(big.byteCount / 1_000_000) MB, "
              + "encode \(ms(start, decodeStart)) ms, decode \(ms(decodeStart, end)) ms")
        let t0 = DispatchTime.now(); _ = try! ResultTable(block: big.block); let t1 = DispatchTime.now()
        print("BENCH re-parse block: \(ms(t0, t1)) ms")
    }

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
