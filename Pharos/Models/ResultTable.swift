import Foundation

/// The rows of a query result, stored by column in one contiguous block.
///
/// Every cell of a real result is text or NULL (PostgreSQL's text format, and
/// DuckDB's `::VARCHAR`), so a column is its UTF-8 bytes, one offset per row
/// and a null bitmap. That is the text itself plus about 4 bytes a cell, where
/// `[[AnyCodable]]` cost a 32-byte existential per cell, a heap array per row
/// (1,280 bytes for a 20-column row, measured) and a heap block per string
/// longer than 15 bytes.
///
/// The block layout ("PRB1") is the SAME in pharos-core, across the FFI, in
/// memory here and in a spill file, so a table can wrap bytes it did not
/// write — a Rust buffer or a memory-mapped file — without copying them.
/// Little-endian:
///
///     "PRB1" | u32 version (1) | u32 rowCount | u32 columnCount
///     per column, each part padded to a multiple of 4 bytes:
///       u32 byteLength | null bitmap, ceil(rows/8) bytes, bit set = NULL
///       | u32 offsets[rows + 1] | UTF-8 bytes (byteLength)
///
/// A value type over immutable storage: copies share the block. Rows are
/// never changed in place; `appending` and `gathering` build a new block.
struct ResultTable {
    fileprivate let storage: ResultTableStorage

    var rowCount: Int { storage.rowCount }
    var columnCount: Int { storage.columnCount }
    var isEmpty: Bool { storage.rowCount == 0 }
    /// The size of the block, for the results budget.
    var byteCount: Int { storage.data.length }
    /// The block itself (shares the storage's bytes; no copy).
    var block: Data { Data(referencing: storage.data) }

    /// An empty table: no rows, `columnCount` columns.
    init(columnCount: Int = 0) {
        var builder = ResultTableBuilder(columnCount: columnCount)
        self = builder.finish()
    }

    /// Wrap a block written elsewhere (pharos-core, a spill file). The bytes
    /// are checked once, here: a block that does not hold together throws
    /// rather than trapping on a later read.
    init(block: Data) throws {
        storage = try ResultTableStorage(data: block as NSData)
    }

    /// Build from cells, row by row. A short row's missing cells are NULL;
    /// the widest row sets the column count.
    init(rows: [[String?]]) {
        var builder = ResultTableBuilder(columnCount: rows.map(\.count).max() ?? 0)
        for row in rows { builder.appendRow(row) }
        self = builder.finish()
    }

    fileprivate init(storage: ResultTableStorage) { self.storage = storage }

    // MARK: Cells

    /// True for a SQL NULL, and for a column past the last one.
    func isNull(_ row: Int, _ column: Int) -> Bool {
        guard column < storage.columnCount else { return true }
        return storage.isNull(row, column)
    }

    /// The cell as text, or nil for a SQL NULL (and for a column past the
    /// last one, which a ragged row used to read as missing).
    func string(_ row: Int, _ column: Int) -> String? {
        guard column < storage.columnCount, !storage.isNull(row, column) else { return nil }
        return storage.withBytes(row, column) { String(decoding: $0, as: UTF8.self) }
    }

    /// The cell as text, "" for a SQL NULL.
    func displayString(_ row: Int, _ column: Int) -> String { string(row, column) ?? "" }

    /// The cell's UTF-8 bytes, or nil for a SQL NULL. The buffer is valid only
    /// inside `body`. For comparisons and hashing without making a String.
    func withUTF8<R>(_ row: Int, _ column: Int, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R? {
        guard column < storage.columnCount, !storage.isNull(row, column) else { return nil }
        return try storage.withBytes(row, column, body)
    }

    /// The number of UTF-8 bytes in a cell (0 for NULL).
    func utf8Count(_ row: Int, _ column: Int) -> Int {
        guard column < storage.columnCount, !storage.isNull(row, column) else { return 0 }
        return storage.byteRange(row, column).count
    }

    subscript(row: Int, column: Int) -> String? { string(row, column) }

    /// One row as text cells. Allocates; for one row, not for a scan.
    func row(_ row: Int) -> [String?] {
        (0..<storage.columnCount).map { string(row, $0) }
    }

    /// Every row as text cells. Allocates the whole result; for tests and
    /// small results only.
    var allRows: [[String?]] { (0..<rowCount).map { row($0) } }

    // MARK: Building new tables

    /// This table with `other`'s rows after its own. An empty table takes the
    /// other's column count.
    func appending(_ other: ResultTable) -> ResultTable {
        if rowCount == 0 && columnCount != other.columnCount { return other }
        if other.rowCount == 0 { return self }
        precondition(columnCount == other.columnCount, "appending a table with another column count")
        var builder = ResultTableBuilder(columnCount: columnCount)
        builder.reserveRows(rowCount + other.rowCount)
        builder.append(contentsOf: self, rows: 0..<rowCount)
        builder.append(contentsOf: other, rows: 0..<other.rowCount)
        return builder.finish()
    }

    /// The rows at `indices`, in that order.
    func gathering(rows indices: [Int]) -> ResultTable {
        var builder = ResultTableBuilder(columnCount: columnCount)
        builder.reserveRows(indices.count)
        for index in indices { builder.append(contentsOf: self, rows: index..<(index + 1)) }
        return builder.finish()
    }

    /// The rows in `range`.
    func slice(_ range: Range<Int>) -> ResultTable {
        var builder = ResultTableBuilder(columnCount: columnCount)
        builder.reserveRows(range.count)
        builder.append(contentsOf: self, rows: range)
        return builder.finish()
    }
}

extension ResultTable: Equatable {
    /// Same cells. Blocks are canonical (one layout per content), so this
    /// compares bytes.
    static func == (lhs: ResultTable, rhs: ResultTable) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.data.isEqual(to: rhs.storage.data as Data)
    }
}

// MARK: - JSON

/// The JSON form is `[[string|null]]`, the shape history and saved Sessions
/// store, so stored results read and write as they always have. The decode
/// streams cells straight into the builder: no array per row.
extension ResultTable: Codable {
    init(from decoder: Decoder) throws {
        var rowsContainer = try decoder.unkeyedContainer()
        func cell(_ cells: inout UnkeyedDecodingContainer) throws -> String? {
            try cells.decodeNil() ? nil : try cells.decode(String.self)
        }
        // The first row sets the column count (every producer writes
        // rectangular rows); a later short row is padded with NULL.
        guard !rowsContainer.isAtEnd else { self = ResultTable(columnCount: 0); return }
        var firstCells = try rowsContainer.nestedUnkeyedContainer()
        var first: [String?] = []
        while !firstCells.isAtEnd { first.append(try cell(&firstCells)) }
        var builder = ResultTableBuilder(columnCount: first.count)
        if let n = rowsContainer.count { builder.reserveRows(n) }
        builder.appendRow(first)
        while !rowsContainer.isAtEnd {
            var cells = try rowsContainer.nestedUnkeyedContainer()
            var column = 0
            while !cells.isAtEnd {
                guard column < builder.columnCount else {
                    throw DecodingError.dataCorruptedError(
                        in: cells, debugDescription: "a row has more cells than the first row")
                }
                builder.append(try cell(&cells))
                column += 1
            }
            builder.finishRow()
        }
        self = builder.finish()
    }

    func encode(to encoder: Encoder) throws {
        var rowsContainer = encoder.unkeyedContainer()
        for r in 0..<rowCount {
            var cells = rowsContainer.nestedUnkeyedContainer()
            for c in 0..<columnCount {
                if let text = string(r, c) { try cells.encode(text) } else { try cells.encodeNil() }
            }
        }
    }
}

// MARK: - Builder

/// Builds a table cell by cell, row-major, then writes the block once.
struct ResultTableBuilder {
    let columnCount: Int
    private var bytes: [[UInt8]]
    private var offsets: [[UInt32]]
    private var nulls: [[UInt8]]
    private(set) var rowCount = 0
    /// The column the next `append` fills.
    private var column = 0

    init(columnCount: Int) {
        self.columnCount = columnCount
        bytes = Array(repeating: [], count: columnCount)
        offsets = Array(repeating: [0], count: columnCount)
        nulls = Array(repeating: [], count: columnCount)
    }

    mutating func reserveRows(_ n: Int) {
        for c in 0..<columnCount {
            offsets[c].reserveCapacity(n + 1)
            nulls[c].reserveCapacity((n + 7) / 8)
        }
    }

    /// The next cell of the current row.
    mutating func append(_ cell: String?) {
        precondition(column < columnCount, "more cells than columns")
        if let cell {
            var text = cell
            text.withUTF8 { bytes[column].append(contentsOf: $0) }
        }
        endCell(isNull: cell == nil)
    }

    /// The next cell of the current row, as UTF-8 bytes (nil = NULL).
    mutating func appendUTF8(_ cell: UnsafeRawBufferPointer?) {
        precondition(column < columnCount, "more cells than columns")
        if let cell { bytes[column].append(contentsOf: cell) }
        endCell(isNull: cell == nil)
    }

    /// End the current row; cells it did not fill are NULL.
    mutating func finishRow() {
        while column < columnCount { endCell(isNull: true) }
        column = 0
        rowCount += 1
    }

    /// One whole row. A short row's missing cells are NULL.
    mutating func appendRow(_ cells: [String?]) {
        precondition(column == 0, "appendRow in the middle of a row")
        for cell in cells.prefix(columnCount) { append(cell) }
        finishRow()
    }

    /// Rows `range` of `table`, which must have this builder's column count.
    mutating func append(contentsOf table: ResultTable, rows range: Range<Int>) {
        precondition(column == 0, "append(contentsOf:) in the middle of a row")
        precondition(table.columnCount == columnCount, "column counts differ")
        guard !range.isEmpty else { return }
        let storage = table.storage
        for c in 0..<columnCount {
            let start = storage.byteRange(range.lowerBound, c).lowerBound
            let end = storage.byteRange(range.upperBound - 1, c).upperBound
            let shift = UInt32(bytes[c].count) &- UInt32(start)
            storage.withRawBytes(c, start..<end) { bytes[c].append(contentsOf: $0) }
            for r in range {
                offsets[c].append(UInt32(storage.byteRange(r, c).upperBound) &+ shift)
                setNull(storage.isNull(r, c), column: c, row: rowCount + (r - range.lowerBound))
            }
        }
        rowCount += range.count
    }

    private mutating func endCell(isNull: Bool) {
        precondition(bytes[column].count <= UInt32.max, "a column holds more than 4 GB of text")
        offsets[column].append(UInt32(bytes[column].count))
        setNull(isNull, column: column, row: rowCount)
        column += 1
    }

    private mutating func setNull(_ isNull: Bool, column c: Int, row: Int) {
        let byte = row >> 3
        if byte >= nulls[c].count { nulls[c].append(0) }
        if isNull { nulls[c][byte] |= UInt8(1 << (row & 7)) }
    }

    /// Write the block. A row left open is finished first.
    mutating func finish() -> ResultTable {
        if column != 0 { finishRow() }
        let bitmapLength = (rowCount + 7) / 8
        func padded(_ n: Int) -> Int { (n + 3) & ~3 }
        var size = 16
        for c in 0..<columnCount {
            size += 4 + padded(bitmapLength) + 4 * (rowCount + 1) + padded(bytes[c].count)
        }
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            var at = 0
            func put(_ value: UInt32) { raw.storeBytes(of: value.littleEndian, toByteOffset: at, as: UInt32.self); at += 4 }
            func put(_ part: [UInt8], paddedTo length: Int) {
                part.withUnsafeBytes { src in
                    if let base = src.baseAddress, !part.isEmpty {
                        (raw.baseAddress! + at).copyMemory(from: base, byteCount: part.count)
                    }
                }
                at += length   // `Data(count:)` is zero-filled, so the padding is zero
            }
            raw.copyBytes(from: Array("PRB1".utf8)); at = 4
            put(1); put(UInt32(rowCount)); put(UInt32(columnCount))
            for c in 0..<columnCount {
                put(UInt32(bytes[c].count))
                var bitmap = nulls[c]
                if bitmap.count < bitmapLength { bitmap += Array(repeating: 0, count: bitmapLength - bitmap.count) }
                put(bitmap, paddedTo: padded(bitmapLength))
                for offset in offsets[c] { put(offset) }
                put(bytes[c], paddedTo: padded(bytes[c].count))
            }
        }
        // A block this builder wrote is valid by construction; the parse
        // still runs so there is one reader for every block.
        return ResultTable(storage: try! ResultTableStorage(data: data as NSData))
    }
}

// MARK: - Storage

enum ResultTableError: Error, Equatable {
    case badBlock(String)
}

/// The parsed block. `NSData` keeps its bytes at one address for its life
/// (also for wrapped Rust buffers and mapped files), so reads go through a
/// raw pointer without `withUnsafeBytes` on every cell.
final class ResultTableStorage {
    let data: NSData
    let rowCount: Int
    let columnCount: Int
    private let base: UnsafeRawPointer
    /// Per column: byte offsets of the bitmap, the offsets array and the text.
    private let bitmapAt: [Int]
    private let offsetsAt: [Int]
    private let textAt: [Int]

    /// Called when the storage goes (M5: deletes a spill file).
    var onRelease: (() -> Void)?

    init(data: NSData) throws {
        self.data = data
        let length = data.length
        guard length >= 16 else { throw ResultTableError.badBlock("shorter than the header") }
        let base = data.bytes
        self.base = base
        func u32(_ at: Int) -> Int { Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        guard u32(0) == 0x3142_5250 else {   // "PRB1" read as a little-endian u32
            throw ResultTableError.badBlock("not a PRB1 block")
        }
        guard u32(4) == 1 else { throw ResultTableError.badBlock("version \(u32(4))") }
        let rows = u32(8), columns = u32(12)
        let bitmapLength = (rows + 7) / 8
        func padded(_ n: Int) -> Int { (n + 3) & ~3 }
        var at = 16
        var bitmapAt: [Int] = [], offsetsAt: [Int] = [], textAt: [Int] = []
        bitmapAt.reserveCapacity(columns); offsetsAt.reserveCapacity(columns); textAt.reserveCapacity(columns)
        for c in 0..<columns {
            guard at + 4 <= length else { throw ResultTableError.badBlock("column \(c) is cut short") }
            let byteLength = u32(at); at += 4
            let need = padded(bitmapLength) + 4 * (rows + 1) + padded(byteLength)
            guard need <= length - at else { throw ResultTableError.badBlock("column \(c) is cut short") }
            bitmapAt.append(at); at += padded(bitmapLength)
            offsetsAt.append(at)
            // Offsets start at 0, never fall, and end at the text's length.
            var previous = 0
            for r in 0...rows {
                let offset = u32(at + 4 * r)
                guard (r == 0 && offset == 0) || (r > 0 && offset >= previous) else {
                    throw ResultTableError.badBlock("column \(c) offsets are out of order at row \(r)")
                }
                previous = offset
            }
            guard previous == byteLength else { throw ResultTableError.badBlock("column \(c) offsets do not end at its length") }
            at += 4 * (rows + 1)
            textAt.append(at); at += padded(byteLength)
        }
        guard at == length else { throw ResultTableError.badBlock("\(length - at) bytes after the last column") }
        rowCount = rows; columnCount = columns
        self.bitmapAt = bitmapAt; self.offsetsAt = offsetsAt; self.textAt = textAt
    }

    deinit { onRelease?() }

    @inline(__always) func isNull(_ row: Int, _ column: Int) -> Bool {
        precondition(row >= 0 && row < rowCount, "row \(row) out of range 0..<\(rowCount)")
        let byte = base.load(fromByteOffset: bitmapAt[column] + (row >> 3), as: UInt8.self)
        return byte & UInt8(1 << (row & 7)) != 0
    }

    @inline(__always) func byteRange(_ row: Int, _ column: Int) -> Range<Int> {
        precondition(row >= 0 && row < rowCount, "row \(row) out of range 0..<\(rowCount)")
        let at = offsetsAt[column] + 4 * row
        let start = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
        let end = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self)))
        return start..<end
    }

    @inline(__always) func withBytes<R>(_ row: Int, _ column: Int, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let range = byteRange(row, column)
        return try body(UnsafeRawBufferPointer(start: base + textAt[column] + range.lowerBound, count: range.count))
    }

    /// Raw text bytes `range` of column `column` (byte offsets within it).
    func withRawBytes<R>(_ column: Int, _ range: Range<Int>, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base + textAt[column] + range.lowerBound, count: range.count))
    }
}
