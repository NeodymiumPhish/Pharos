import AppKit
import UniformTypeIdentifiers

// MARK: - Copy Data

struct CopyData {
    let columnNames: [String]
    let columnIndices: [Int]
    /// One entry per column. `nil` is SQL NULL; `""` is an empty string. The
    /// two used to arrive as the same `""`, so an empty string exported as
    /// `NULL` and a text value that read `NULL` did too. Each format decides
    /// its own rendering of nil: the SQL builders write `NULL`, JSON writes
    /// `null`, the text formats write an empty field.
    let rows: [[String?]]
    let includeHeaders: Bool
}

// MARK: - Copy Export Delegate

protocol ResultsCopyExportDelegate: AnyObject {
    func copyExportWindow() -> NSWindow?
}

// MARK: - ResultsCopyExport

/// Copy and export carry RAW BYTES, never the escaped display text.
///
/// The grid escapes hostile scalars for DISPLAY (`ResultCellText.rendered` →
/// `DisplayEscape`) so a bidi override cannot make a cell read as a filename the
/// data does not hold. That transform must stop at the label. This class reads
/// `AnyCodable.displayString` straight off the model instead, because an
/// analyst pastes indicators out of here into other systems, and an indicator
/// that arrived as `10.0.0.1<U+0020>` is a corrupt indicator — the copy would
/// silently no longer be the thing that was on screen.
///
/// So: nothing in this file may call `ResultCellText` or `DisplayEscape`.
class ResultsCopyExport: NSObject {
    private let tableView: NSTableView
    private let copyButton: NSButton
    private let exportButton: NSButton

    // Data state (pushed by VC)
    var columns: [ColumnDef] = []
    var rows: [[AnyCodable]] = []
    var displayRows: [Int] = []
    var columnCategories: [PGTypeCategory] = []

    /// Cell selection state, pushed by the VC. When set, copy/export uses the cell range.
    var cellSelection: CellSelectionState?

    /// DATA row indices matching at least one tag, pushed by the VC with each
    /// tag-map landing.
    var taggedRows: Set<Int> = []

    /// "Tagged rows only": per-grid and transient by design — a sticky global
    /// toggle would silently filter copies long after the analyst forgot it.
    private var taggedOnly = false

    /// Whether to include column headers in copy/export output.
    ///
    /// Lives in `AppSettings.results.copyIncludeHeaders` (Settings ▸ Results ▸
    /// Copy) and is PUSHED here by `ResultsGridVC`; the menu item and the
    /// popover checkbox report a change back through
    /// `onIncludeHeadersChanged` rather than writing a store themselves. It
    /// used to be a `UserDefaults` key of this class's own, which is why
    /// `SettingsMigration` exists.
    var includeHeaders = true

    /// Called when the user flips "Include Headers" from the menu or the
    /// popover. The grid writes it to Settings; nil leaves this class working
    /// exactly as it did for the standalone harnesses.
    var onIncludeHeadersChanged: ((Bool) -> Void)?

    /// Whether a copy also writes the `.html` rich-text flavour (Settings ▸
    /// Results ▸ Copy). Off leaves the pasteboard with plain text and
    /// `.tabularText` only, so a paste into Mail or Notes arrives as text
    /// rather than as a styled table.
    var writesRichText = true

    /// What ⌘C copies, pushed by `ResultsGridVC` from Settings ▸ Results.
    /// TSV until it is — which is what this class did unconditionally before
    /// the setting existed.
    var defaultCopyAction: ((Any?) -> Void)?

    weak var delegate: ResultsCopyExportDelegate?

    /// Base name for the CSV file a drag out of the grid promises, without the
    /// extension. Pushed by the VC from the result's own table name when the
    /// core attributed one; the default is what an unattributed result drags
    /// out as.
    var dragFileBaseName: String = String(localized: "Results")

    /// The writer behind the drag currently in flight. `NSFilePromiseProvider`
    /// does NOT retain its delegate, and the provider is its own delegate here,
    /// so nothing else would keep it alive between the drag starting and the
    /// destination asking for the file.
    private var dragProvider: ResultsDragProvider?

    init(tableView: NSTableView, copyButton: NSButton, exportButton: NSButton) {
        self.tableView = tableView
        self.copyButton = copyButton
        self.exportButton = exportButton
        super.init()
        // The grid's table view starts the drag (it owns the mouse), but the
        // payload is this class's job — it is the one place that knows how the
        // selection turns into TSV, HTML and CSV. Wiring it here keeps the
        // whole drag-out feature in the two files that already own copy.
        (tableView as? ResultsTableView)?.dragWriterProvider = { [weak self] in
            self?.makeDragWriter()
        }
    }

    // MARK: - Drag Out

    /// Builds the pasteboard writer for a drag of the current selection, or
    /// nil when there is nothing to drag.
    ///
    /// One writer, not two: a single dragging item carries the three text
    /// representations a copy writes AND the promise of a CSV file, so a drop
    /// on a text editor pastes the rows while a drop on the Finder writes one
    /// file. Two items would have handed the Finder both — a file and a text
    /// clipping — for one gesture.
    ///
    /// The `CopyData` snapshot is taken here, on the main thread, off the live
    /// model. The CSV — the big one — is a real promise and is written later
    /// on the provider's own queue; the text forms are built when the drag
    /// starts (see `ResultsDragProvider`, which explains why they cannot be
    /// promised too).
    func makeDragWriter() -> NSPasteboardWriting? {
        guard let data = gatherData() else { return nil }
        let provider = ResultsDragProvider(data: data, fileName: Self.dragFileName(base: dragFileBaseName),
                                           writesRichText: writesRichText)
        dragProvider = provider
        return provider
    }

    /// `base.csv`, with anything that cannot travel in a file name removed.
    /// A name that sanitises away to nothing falls back to "Results", so the
    /// promise always has a name to write under.
    static func dragFileName(base: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let cleaned = base.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "Results" : String(cleaned.prefix(80))
        return "\(name).csv"
    }

    // MARK: - Selection Helper

    private var hasSelection: Bool {
        (cellSelection?.selectedRange != nil) || !tableView.selectedRowIndexes.isEmpty
    }

    // MARK: - Data Gathering

    /// What a cell range yielded. `scopedOut` exists so `gatherData()` can tell
    /// "there is no cell range" apart from "the tagged filter emptied the one
    /// there is" — the second must NOT fall through to the row path, or asking
    /// for the tagged rows of a chosen block would silently copy the tagged
    /// rows of the whole visible result instead: the opposite of narrowing.
    private enum CellRangeGather {
        case none
        case scopedOut
        case data(CopyData)
    }

    /// Which table columns copy, export, share and drag carry: the data
    /// columns the user can SEE. The row-number column is chrome, and a column
    /// hidden from the header's menu is hidden on purpose — what leaves the grid
    /// is the table on screen, so a hidden column never rides along in a paste.
    static func isCopyable(_ column: NSTableColumn) -> Bool {
        column.identifier.rawValue != "__rownum__" && !column.isHidden
    }

    /// Gathers data from the selected cell range.
    private func gatherCellRangeData() -> CellRangeGather {
        guard let selection = cellSelection, let range = selection.selectedRange else { return .none }

        let tableCols = tableView.tableColumns
        let selectedColIds = (range.topLeft.column...range.bottomRight.column).compactMap { idx -> String? in
            guard idx >= 0, idx < tableCols.count, Self.isCopyable(tableCols[idx]) else { return nil }
            return tableCols[idx].identifier.rawValue
        }
        guard !selectedColIds.isEmpty else { return .none }

        let resolved = selectedColIds.compactMap { id -> (name: String, index: Int)? in
            guard let idx = colIndex(from: id), idx < self.columns.count else { return nil }
            return (self.columns[idx].name, idx)
        }
        let displayNames = resolved.map(\.name)
        let indices = resolved.map(\.index)

        var rowData: [[String?]] = []
        var droppedByScope = false
        for row in range.topLeft.row...range.bottomRight.row {
            guard row >= 0, row < displayRows.count else { continue }
            let dataIdx = displayRows[row]
            guard dataIdx < rows.count else { continue }
            guard TagCopyScope.include(dataRow: dataIdx, taggedOnly: taggedOnly,
                                       taggedRows: taggedRows) else {
                droppedByScope = true
                continue
            }
            let data = rows[dataIdx]
            let values = indices.map { idx in
                idx < data.count && !data[idx].isNull ? data[idx].displayString : nil
            }
            rowData.append(values)
        }

        // An out-of-bounds range still reports `.none` and keeps its old
        // fall-through; only the scope may end the action here.
        guard !rowData.isEmpty else { return droppedByScope ? .scopedOut : .none }
        return .data(CopyData(columnNames: displayNames, columnIndices: indices,
                              rows: rowData, includeHeaders: includeHeaders))
    }

    /// Gathers data for copy/export. Uses selected rows if any, otherwise all displayed rows.
    func gatherData() -> CopyData? {
        // If a cell range is selected, use that instead of row-based selection
        switch gatherCellRangeData() {
        case .data(let cellRangeData):
            return cellRangeData
        case .scopedOut:
            // Terminal, and audible: ⌘C and the context menu show no caption,
            // so a silent nil would be indistinguishable from a copy that
            // worked, and the analyst would paste whatever was there before.
            NSSound.beep()
            return nil
        case .none:
            break
        }

        let selectedRows = tableView.selectedRowIndexes

        let colIds = tableView.tableColumns.compactMap { col -> String? in
            Self.isCopyable(col) ? col.identifier.rawValue : nil
        }
        guard !colIds.isEmpty else { return nil }

        let resolved = colIds.compactMap { id -> (name: String, index: Int)? in
            guard let idx = colIndex(from: id), idx < self.columns.count else { return nil }
            return (self.columns[idx].name, idx)
        }
        let displayNames = resolved.map(\.name)
        let indices = resolved.map(\.index)

        var rowData: [[String?]] = []

        if !selectedRows.isEmpty {
            for row in selectedRows {
                guard row < displayRows.count,
                      TagCopyScope.include(dataRow: displayRows[row], taggedOnly: taggedOnly,
                                           taggedRows: taggedRows) else { continue }
                let data = rows[displayRows[row]]
                let values = indices.map { idx in
                    idx < data.count && !data[idx].isNull ? data[idx].displayString : nil
                }
                rowData.append(values)
            }
        } else {
            for row in 0..<displayRows.count {
                guard TagCopyScope.include(dataRow: displayRows[row], taggedOnly: taggedOnly,
                                           taggedRows: taggedRows) else { continue }
                let data = rows[displayRows[row]]
                let values = indices.map { idx in
                    idx < data.count && !data[idx].isNull ? data[idx].displayString : nil
                }
                rowData.append(values)
            }
        }

        guard !rowData.isEmpty else { return nil }
        return CopyData(columnNames: displayNames, columnIndices: indices, rows: rowData, includeHeaders: includeHeaders)
    }

    // MARK: - Selection Summary

    /// Column/row counts that copy/export would produce for the current
    /// selection. Mirrors `gatherData()` so the popover caption matches the
    /// actual output. `isSelection` is false when nothing is selected — in
    /// that case the whole displayed result set is the target.
    func selectionSummary() -> (columns: Int, rows: Int, isSelection: Bool) {
        // Cell range selection — same shape as gatherCellRangeData().
        if let selection = cellSelection, let range = selection.selectedRange {
            let tableCols = tableView.tableColumns
            let selectedColIds = (range.topLeft.column...range.bottomRight.column).compactMap { idx -> String? in
                guard idx >= 0, idx < tableCols.count, Self.isCopyable(tableCols[idx]) else { return nil }
                return tableCols[idx].identifier.rawValue
            }
            let colCount = selectedColIds.filter { id in
                guard let idx = colIndex(from: id) else { return false }
                return idx < columns.count
            }.count
            let lo = max(0, range.topLeft.row)
            let hi = min(displayRows.count - 1, range.bottomRight.row)
            var rowCount = 0
            if hi >= lo {
                for row in lo...hi where TagCopyScope.include(
                    dataRow: displayRows[row], taggedOnly: taggedOnly,
                    taggedRows: taggedRows) { rowCount += 1 }
            }
            // A scope-emptied range is terminal in gatherData(), so the caption
            // must report zero rows rather than describing the whole visible
            // set the copy will now refuse to produce.
            let scopedOut = hi >= lo && rowCount == 0 && taggedOnly && !taggedRows.isEmpty
            if colCount > 0 && (rowCount > 0 || scopedOut) {
                return (colCount, rowCount, true)
            }
        }

        // All data columns, resolved exactly like gatherData().
        let allColCount = tableView.tableColumns.filter { col in
            guard Self.isCopyable(col), let idx = colIndex(from: col.identifier.rawValue) else { return false }
            return idx < columns.count
        }.count

        // Row selection.
        let selectedRows = tableView.selectedRowIndexes
        if !selectedRows.isEmpty {
            let rowCount = selectedRows.filter {
                $0 < displayRows.count && TagCopyScope.include(
                    dataRow: displayRows[$0], taggedOnly: taggedOnly,
                    taggedRows: taggedRows)
            }.count
            return (allColCount, rowCount, true)
        }

        // Whole result set.
        let visibleCount = displayRows.filter {
            TagCopyScope.include(dataRow: $0, taggedOnly: taggedOnly,
                                 taggedRows: taggedRows)
        }.count
        return (allColCount, visibleCount, false)
    }

    /// Human-readable caption for the copy/export popover, e.g.
    /// "Selected: 3 columns × 25 rows", "All 5 columns × 1,240 rows",
    /// "Tagged: 5 columns × 12 rows" or "Tagged selection: 3 columns × 4 rows".
    ///
    /// Internal rather than private so `scripts/test-tag-copy-export.sh` can
    /// assert the prefix: this string is the only thing that tells the analyst
    /// their copy was narrowed to tagged rows, and it must not claim a scope
    /// that `TagCopyScope.include` is not actually applying.
    func summaryCaption() -> String {
        let s = selectionSummary()
        let cols = Self.countLabel(s.columns, singular: "column", plural: "columns")
        let rows = Self.countLabel(s.rows, singular: "row", plural: "rows")
        let scoped = taggedOnly && !taggedRows.isEmpty
        let prefix = s.isSelection
            ? (scoped ? "Tagged selection:" : "Selected:")
            : (scoped ? "Tagged:" : "All")
        return "\(prefix) \(cols) × \(rows)"
    }

    private static func countLabel(_ n: Int, singular: String, plural: String) -> String {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return "\(formatted) \(n == 1 ? singular : plural)"
    }

    // MARK: - Copy Support

    @objc func copy(_ sender: Any?) {
        if let defaultCopyAction {
            defaultCopyAction(sender)
        } else {
            copyAsTSV(sender)
        }
    }

    /// Format a CopyData payload off the main thread, then set the pasteboard on main.
    /// For large selections (10k+ rows) the join/escape/SQL build was the longest
    /// main-thread block in the app; this keeps the UI responsive during copies.
    ///
    /// Every copy writes three representations of the same selection onto one
    /// `NSPasteboardItem`: `.string` is the chosen format (TSV, CSV, Markdown,
    /// SQL INSERT or SQL WITH — whichever button/selector fired), `.tabularText`
    /// is always the TSV form regardless of that choice (so a paste into a
    /// spreadsheet or a table-aware editor lands as a table even when the
    /// analyst picked "Copy as SQL INSERT"), and `.html` is a plain `<table>` for
    /// apps that prefer rich text (Mail, Notes, a browser's editable field).
    private func copyOnBackground(_ format: @escaping (CopyData) -> String) {
        guard let data = gatherData() else { return }
        // Read on the main thread, where it is written, and carried into the
        // background block as a value.
        let richText = writesRichText
        DispatchQueue.global(qos: .userInitiated).async {
            let text = format(data)
            let tabularText = Self.tsvText(data: data)
            let html = richText ? Self.htmlTable(data: data, includeHeaders: data.includeHeaders) : nil
            DispatchQueue.main.async {
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                item.setString(tabularText, forType: .tabularText)
                if let html { item.setString(html, forType: .html) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item])
            }
        }
    }

    @objc func copyAsTSV(_: Any?) {
        copyOnBackground { data in Self.tsvText(data: data) }
    }

    /// The TSV text for a whole `CopyData` payload: rows joined by tabs, one
    /// per line, with the header row prepended when headers are on. Shared by
    /// "Copy as TSV", "Export as TSV" and the `.tabularText` pasteboard
    /// representation every copy now also writes — one join, one escaping rule.
    static func tsvText(data: CopyData) -> String {
        var lines = data.rows.map { $0.map { Self.tsvField($0) }.joined(separator: "\t") }
        if data.includeHeaders {
            lines.insert(data.columnNames.joined(separator: "\t"), at: 0)
        }
        return lines.joined(separator: "\n")
    }

    @objc func copyAsCSV(_: Any?) {
        copyOnBackground { data in Self.csvText(data: data) }
    }

    /// The CSV text for a whole `CopyData` payload: RFC 4180 escaping through
    /// `csvEscape`, one row per line, the header row first when headers are
    /// on. Shared by "Copy as CSV", "Export as CSV", "Share…" and the drag-out
    /// file promise — one escaping rule for every CSV that leaves the grid.
    static func csvText(data: CopyData) -> String {
        var lines = data.rows.map { $0.map { Self.csvEscape($0 ?? "") }.joined(separator: ",") }
        if data.includeHeaders {
            let header = data.columnNames.map { Self.csvEscape($0) }.joined(separator: ",")
            lines.insert(header, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    @objc func copyAsMarkdown(_: Any?) {
        copyOnBackground { data in
            let rows = data.rows.map { "| " + $0.map { Self.markdownField($0) }.joined(separator: " | ") + " |" }
            if data.includeHeaders {
                let header = "| " + data.columnNames.joined(separator: " | ") + " |"
                let divider = "| " + data.columnNames.map { _ in "---" }.joined(separator: " | ") + " |"
                return ([header, divider] + rows).joined(separator: "\n")
            } else {
                return rows.joined(separator: "\n")
            }
        }
    }

    @objc func copyAsSQLInsert(_: Any?) {
        let cats = columnCategories
        copyOnBackground { data in
            Self.sqlInsertStatements(data: data, categories: cats)
        }
    }

    /// Builds the `INSERT INTO table_name (...) VALUES (...);` text that
    /// "Copy as SQL INSERT" puts on the pasteboard. Internal and pure for the
    /// same reason as `sqlWithStatement`, and it quotes the column names
    /// through the same shared quoter.
    static func sqlInsertStatements(data: CopyData, categories: [PGTypeCategory]) -> String {
        let colList = data.columnNames.map { quotedSqlIdentifier($0) }.joined(separator: ", ")
        let statements = data.rows.map { row in
            let values = zip(data.columnIndices, row).map { (colIdx, val) -> String in
                guard let val else { return "NULL" }
                let category = colIdx < categories.count ? categories[colIdx] : .string
                switch category {
                case .numeric:
                    return val
                case .boolean:
                    return Self.sqlBooleanLiteral(val)
                default:
                    return "'\(val.replacingOccurrences(of: "'", with: "''"))'"
                }
            }
            return "INSERT INTO table_name (\(colList)) VALUES (\(values.joined(separator: ", ")));"
        }
        return statements.joined(separator: "\n")
    }

    @objc func copyAsSQLWith(_: Any?) {
        let cats = columnCategories
        let cols = columns
        copyOnBackground { data in
            Self.sqlWithStatement(data: data, categories: cats, columns: cols)
        }
    }

    /// Builds the `WITH cte(...) AS (VALUES ...)` text that "Copy as SQL WITH"
    /// puts on the pasteboard.
    ///
    /// Internal and pure so `scripts/test-sql-copy-format.sh` can assert the
    /// text: the column list must survive a paste into the editor, and a column
    /// that carries an alias (`min(ts) AS "First Seen"`), an uppercase letter or
    /// PG's own `?column?` is NOT a bare identifier. Every name therefore goes
    /// through `quotedSqlIdentifier`, which also doubles an embedded `"` so a
    /// hostile alias cannot break out of the column list.
    static func sqlWithStatement(data: CopyData,
                                 categories: [PGTypeCategory],
                                 columns: [ColumnDef]) -> String {
        // copyAsSQLWith historically suppressed headers regardless of the
        // user toggle (the WITH/cte() carries column names already), so
        // preserve that behavior here in the off-thread path.
        let _ = data.includeHeaders

        let colList = data.columnNames.map { quotedSqlIdentifier($0) }.joined(separator: ", ")
        let valueRows = data.rows.enumerated().map { (rowIdx, row) in
            let values = zip(data.columnIndices, row).map { (colIdx, val) -> String in
                let pgType = colIdx < columns.count ? columns[colIdx].dataType : "text"
                // NULLs in row 0 still need the type cast — otherwise PG has
                // nothing to anchor type inference on for that column and
                // mixed-type unification across rows can fail downstream.
                guard let val else {
                    return rowIdx == 0 ? "NULL::\(pgType)" : "NULL"
                }
                let category = colIdx < categories.count ? categories[colIdx] : .string
                let literal: String
                switch category {
                case .numeric:
                    literal = val
                case .boolean:
                    literal = Self.sqlBooleanLiteral(val)
                default:
                    literal = "'\(val.replacingOccurrences(of: "'", with: "''"))'"
                }
                // Cast on first row so PG infers types for the rest. Boolean
                // literals already type themselves via the TRUE/FALSE keyword
                // (or the embedded ::boolean cast for unrecognized forms), so
                // skip the extra cast there to avoid double-cast noise.
                if rowIdx == 0 && category != .boolean {
                    return "\(literal)::\(pgType)"
                }
                return literal
            }
            return "    (\(values.joined(separator: ", ")))"
        }

        return "WITH cte(\(colList)) AS (\n  VALUES\n\(valueRows.joined(separator: ",\n"))\n)\nSELECT * FROM cte;"
    }

    /// Normalize a string from a boolean-typed column to a SQL boolean literal.
    /// PostgreSQL surfaces booleans through its text protocol as "t"/"f", which
    /// display nicely in the grid but are bare identifiers when emitted into
    /// SQL — so `f` would be parsed as a column reference. Map the common
    /// forms to the unquoted SQL keywords TRUE / FALSE, falling back to a
    /// quoted-and-cast string so PG can apply its own lenient parsing.
    private static func sqlBooleanLiteral(_ val: String) -> String {
        switch val.lowercased() {
        case "t", "true", "y", "yes", "on", "1": return "TRUE"
        case "f", "false", "n", "no", "off", "0": return "FALSE"
        default:
            let escaped = val.replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)'::boolean"
        }
    }

    static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            // RFC 4180 CSV quoting doubles embedded quotes. This shares the
            // mechanic with SQL identifier quoting but is a separate domain:
            // exported bytes must stay exact, so it keeps its own quoting and
            // must not track changes to the SQL quoter.
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// One TSV field. NULL is an empty field. A value holding a tab, a line
    /// break or a quote is quoted the CSV way — TSV has no standard of its
    /// own, and this is the form spreadsheets read back as one cell. Without
    /// it an embedded tab shifted every following column on paste.
    static func tsvField(_ s: String?) -> String {
        guard let s else { return "" }
        if s.contains("\t") || s.contains("\n") || s.contains("\r") || s.contains("\"") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// One Markdown table cell. NULL is empty; a `|` is escaped so it cannot
    /// split the row; line breaks become `<br>`, the only form a table cell
    /// can carry.
    static func markdownField(_ s: String?) -> String {
        guard let s else { return "" }
        return s.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    /// Escape the four characters that would otherwise be read as markup:
    /// `&` first (so it doesn't double-escape the entities this just wrote),
    /// then `<`, `>` and `"`.
    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A plain `<table>` for the `.html` pasteboard representation every copy
    /// now writes: no styling, no attributes — just headers (when on) and
    /// rows, escaped, with a SQL NULL as an empty `<td></td>` (the same
    /// "nil is a distinct value, not an empty string" rule the other formats
    /// follow — see `CopyData.rows`).
    static func htmlTable(data: CopyData, includeHeaders: Bool) -> String {
        var html = "<table>"
        if includeHeaders {
            let headerCells = data.columnNames.map { "<th>\(htmlEscape($0))</th>" }.joined()
            html += "<thead><tr>\(headerCells)</tr></thead>"
        }
        let bodyRows = data.rows.map { row -> String in
            let cells = row.map { cell -> String in
                guard let cell else { return "<td></td>" }
                return "<td>\(htmlEscape(cell))</td>"
            }.joined()
            return "<tr>\(cells)</tr>"
        }.joined()
        html += "<tbody>\(bodyRows)</tbody></table>"
        return html
    }

    // MARK: - Copy Popover

    private var activePopover: NSPopover?

    @objc func showCopyMenu() {
        if let existing = activePopover, existing.isShown {
            existing.close()
            activePopover = nil
            return
        }
        let prefix = hasSelection ? "Copy selection" : "Copy"
        let items: [(String, Selector)] = [
            ("\(prefix) as TSV", #selector(copyAsTSV)),
            ("\(prefix) as CSV", #selector(copyAsCSV)),
            ("\(prefix) as Markdown", #selector(copyAsMarkdown)),
            ("\(prefix) as SQL INSERT", #selector(copyAsSQLInsert)),
            ("\(prefix) as SQL WITH", #selector(copyAsSQLWith)),
        ]
        showPopover(from: copyButton, items: items)
    }

    // MARK: - Export Popover

    @objc func showExportMenu() {
        if let existing = activePopover, existing.isShown {
            existing.close()
            activePopover = nil
            return
        }
        let prefix = hasSelection ? "Export selection" : "Export"
        let items: [(String, Selector)] = [
            ("\(prefix) as CSV\u{2026}", #selector(exportAsCSV)),
            ("\(prefix) as TSV\u{2026}", #selector(exportAsTSV)),
            ("\(prefix) as JSON\u{2026}", #selector(exportAsJSON)),
            ("\(prefix) as SQL INSERT\u{2026}", #selector(exportAsSQLInsert)),
            ("\(prefix) as Markdown\u{2026}", #selector(exportAsMarkdown)),
            (String(localized: "Share\u{2026}"), #selector(shareResults)),
        ]
        showPopover(from: exportButton, items: items)
    }

    // MARK: - Share

    /// The picker must outlive `show(relativeTo:)`: it is the delegate-less
    /// owner of the menu it presents, and AppKit does not retain it.
    private var activeSharePicker: NSSharingServicePicker?

    /// Where "Share…" writes its CSV files. A share extension may still be
    /// reading a file after the picker closes, so nothing is deleted per share;
    /// the whole folder goes at quit (`AppDelegate.applicationWillTerminate`).
    static var shareFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Pharos/Share", isDirectory: true)
    }

    static func cleanUpShareFiles() {
        try? FileManager.default.removeItem(at: shareFolder)
    }

    /// "Share…" in the export popover: the selection (or the whole result) as a
    /// CSV file handed to the system share sheet, anchored on the Export button.
    /// A file, not a string, so Mail attaches it and AirDrop sends it as a
    /// document; the CSV goes through the same `csvText` as Copy and Export.
    @objc private func shareResults(_: Any?) {
        guard let data = gatherData() else { return }
        activePopover?.close()
        activePopover = nil
        let folder = Self.shareFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent("Results.csv")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Self.csvText(data: data).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let picker = NSSharingServicePicker(items: [url])
                self.activeSharePicker = picker
                picker.show(relativeTo: self.exportButton.bounds, of: self.exportButton, preferredEdge: .minY)
            }
        }
    }

    /// Builds the popover's view controller.
    ///
    /// Internal rather than private so `scripts/test-tag-copy-export.sh` can
    /// press the real checkbox: which state reaches the popover, and which
    /// callback each box is wired to, is exactly what an ordinary copy-paste
    /// fault gets wrong — and the popover carries the five format buttons, so
    /// a wrong wiring here copies the wrong rows.
    func makePopoverVC(items: [(String, Selector)]) -> CopyExportPopoverVC {
        CopyExportPopoverVC(
            onSummary: { [weak self] in self?.summaryCaption() ?? "" },
            includeHeaders: includeHeaders,
            taggedOnly: taggedRows.isEmpty ? nil : taggedOnly,
            items: items,
            target: self,
            onToggleHeaders: { [weak self] newValue in
                guard let self else { return }
                self.includeHeaders = newValue
                self.onIncludeHeadersChanged?(newValue)
            },
            onToggleTagged: { [weak self] newValue in
                self?.taggedOnly = newValue
            },
            onAction: { [weak self] in
                self?.activePopover?.close()
                self?.activePopover = nil
            }
        )
    }

    private func showPopover(from button: NSButton, items: [(String, Selector)]) {
        let popover = NSPopover()
        popover.contentViewController = makePopoverVC(items: items)
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        activePopover = popover
    }

    private func exportToFile(filename: String, contentType: UTType, generator: @escaping (CopyData) -> String) {
        guard let data = gatherData(), let window = delegate?.copyExportWindow() else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [contentType]

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            // Format + write off main — multi-MB exports otherwise stall the UI
            // until the file lands on disk.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let content = generator(data)
                    try content.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert(error: error)
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc private func exportAsCSV(_: Any?) {
        exportToFile(filename: "export.csv", contentType: .commaSeparatedText) { data in
            Self.csvText(data: data)
        }
    }

    @objc private func exportAsTSV(_: Any?) {
        exportToFile(filename: "export.tsv", contentType: .tabSeparatedText) { data in
            Self.tsvText(data: data)
        }
    }

    @objc private func exportAsJSON(_: Any?) {
        guard let data = gatherData(), let window = delegate?.copyExportWindow() else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "export.json"
        panel.allowedContentTypes = [.json]

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // NULL becomes JSON `null`, not `""`.
                    let jsonArray: [[String: Any]] = data.rows.map { row in
                        let values: [Any] = row.map { $0.map { $0 as Any } ?? NSNull() }
                        return Dictionary(zip(data.columnNames, values), uniquingKeysWith: { _, last in last })
                    }
                    let jsonData = try JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys])
                    try jsonData.write(to: url)
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert(error: error)
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc private func exportAsSQLInsert(_: Any?) {
        // Same builder as "Copy as SQL INSERT": one quoting rule, one NULL
        // rule. The export used to keep its own copy that wrapped names in
        // bare quotes, so an alias with an embedded `"` broke the file but
        // not the pasteboard text.
        let cats = columnCategories
        exportToFile(filename: "export.sql", contentType: UTType(filenameExtension: "sql") ?? .plainText) { data in
            Self.sqlInsertStatements(data: data, categories: cats)
        }
    }

    @objc private func exportAsMarkdown(_: Any?) {
        exportToFile(filename: "export.md", contentType: UTType(filenameExtension: "md") ?? .plainText) { data in
            let rows = data.rows.map { "| " + $0.map { Self.markdownField($0) }.joined(separator: " | ") + " |" }
            if data.includeHeaders {
                let header = "| " + data.columnNames.joined(separator: " | ") + " |"
                let divider = "| " + data.columnNames.map { _ in "---" }.joined(separator: " | ") + " |"
                return ([header, divider] + rows).joined(separator: "\n")
            } else {
                return rows.joined(separator: "\n")
            }
        }
    }

    // MARK: - Context Menu

    @objc private func toggleIncludeHeaders() {
        includeHeaders.toggle()
        onIncludeHeadersChanged?(includeHeaders)
    }

    @objc private func toggleTaggedOnly() {
        taggedOnly.toggle()
    }

    /// The copy section: items 10 (headers toggle), 11 (tagged-rows scope) and
    /// 1-5 (formats). Item 11 sits outside the 1-10 blanket enable below
    /// because it is the one item that must stay DISABLED — an untagged result
    /// has nothing to scope to.
    ///
    /// The menu is owned by `ResultsTagController` since Phase 3; this class
    /// only supplies and updates its own items.
    func addCopyItems(to menu: NSMenu) {
        let headers = menu.addItem(withTitle: "Include Headers", action: #selector(toggleIncludeHeaders), keyEquivalent: "")
        headers.tag = 10
        headers.target = self

        let tagged = menu.addItem(withTitle: "Tagged Rows Only",
                                  action: #selector(toggleTaggedOnly), keyEquivalent: "")
        tagged.tag = 11
        tagged.target = self

        menu.addItem(.separator())

        let tsv = menu.addItem(withTitle: "Copy as TSV", action: #selector(copyAsTSV), keyEquivalent: "")
        tsv.tag = 1
        tsv.target = self
        let csv = menu.addItem(withTitle: "Copy as CSV", action: #selector(copyAsCSV), keyEquivalent: "")
        csv.tag = 2
        csv.target = self
        let md = menu.addItem(withTitle: "Copy as Markdown", action: #selector(copyAsMarkdown), keyEquivalent: "")
        md.tag = 3
        md.target = self
        let sql = menu.addItem(withTitle: "Copy as SQL INSERT", action: #selector(copyAsSQLInsert), keyEquivalent: "")
        sql.tag = 4
        sql.target = self
        let sqlWith = menu.addItem(withTitle: "Copy as SQL WITH", action: #selector(copyAsSQLWith), keyEquivalent: "")
        sqlWith.tag = 5
        sqlWith.target = self
    }

    /// The per-open refresh the old menuNeedsUpdate did.
    func updateCopyItems(in menu: NSMenu) {
        let prefix = hasSelection ? "Copy selection" : "Copy"
        for item in menu.items {
            switch item.tag {
            case 1: item.title = "\(prefix) as TSV"
            case 2: item.title = "\(prefix) as CSV"
            case 3: item.title = "\(prefix) as Markdown"
            case 4: item.title = "\(prefix) as SQL INSERT"
            case 5: item.title = "\(prefix) as SQL WITH"
            case 10: item.state = includeHeaders ? .on : .off
            case 11:
                item.state = taggedOnly ? .on : .off
                item.isEnabled = !taggedRows.isEmpty
            default: break
            }
            if item.tag >= 1 && item.tag <= 10 { item.isEnabled = true }
        }
    }
}

// MARK: - Drag Provider

/// The pasteboard writer for a drag out of the results grid: a CSV file
/// promise that ALSO answers the three text types a copy writes.
///
/// It is its own `NSFilePromiseProviderDelegate` because the payload — one
/// `CopyData` snapshot — is the only state either role needs; splitting them
/// would mean two objects holding the same rows.
///
/// Every representation is built on demand: the text types are declared
/// `.promised`, so `pasteboardPropertyList(forType:)` runs only if the
/// destination asks for them, and the CSV is written on `queue`, off the main
/// thread — the same "snapshot on main, format off main" split the copy path
/// uses for large selections.
final class ResultsDragProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {

    /// The selection as it stood when the drag began.
    let data: CopyData

    /// File name the promise writes under, e.g. `public.users.csv`.
    let fileName: String

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Settings ▸ Results ▸ Copy. Defaulted so the standalone harnesses, and
    /// any caller that does not care, get the behaviour that shipped.
    let writesRichText: Bool

    init(data: CopyData, fileName: String, writesRichText: Bool = true) {
        self.data = data
        self.fileName = fileName
        self.writesRichText = writesRichText
        super.init()
        self.fileType = UTType.commaSeparatedText.identifier
        self.delegate = self
    }

    // MARK: NSPasteboardWriting

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        // `.html` only when Settings ▸ Results ▸ Copy asks for rich text, so a
        // drag out and a copy offer the same flavours.
        super.writableTypes(for: pasteboard) + [.string, .tabularText] + (writesRichText ? [.html] : [])
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        // `.string` and `.tabularText` are both the TSV form, exactly as a
        // copy writes them — a drop into a spreadsheet lands as a table.
        case .string, .tabularText:
            return tsv
        case .html:
            return html
        default:
            return super.pasteboardPropertyList(forType: type)
        }
    }

    /// Built once each, on first request.
    ///
    /// These are NOT declared `.promised`: a promised type on an
    /// `NSFilePromiseProvider` is advertised on the drag pasteboard but reads
    /// back as nil, so a drop into a text view or a spreadsheet silently
    /// delivered nothing. The text is therefore formatted when the drag
    /// starts, like `NSPasteboardWriting` normally does. The CSV — the big one
    /// for a large selection — stays a real promise and is still written off
    /// the main thread, on `queue`.
    private lazy var tsv: String = ResultsCopyExport.tsvText(data: data)
    private lazy var html: String = ResultsCopyExport.htmlTable(data: data,
                                                                includeHeaders: data.includeHeaders)

    // MARK: NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            try ResultsCopyExport.csvText(data: data)
                .write(to: url, atomically: true, encoding: .utf8)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}

// MARK: - Copy/Export Popover VC

/// Popover view controller that shows an "Include Headers" checkbox
/// and a list of format buttons, styled like Xcode's debug area popovers.
class CopyExportPopoverVC: NSViewController {

    /// Recomputed, never a captured string: ticking "Tagged Rows Only" changes
    /// the counts, and the five format buttons sit in this same popover — so a
    /// caption frozen at open time would promise 1,240 rows next to a button
    /// that copies 12. `includeHeaders` does not move the counts, which is why
    /// it never exposed this.
    private let onSummary: () -> String
    private let initialIncludeHeaders: Bool
    /// nil hides the row (no tag map to scope on).
    private let initialTaggedOnly: Bool?
    private let items: [(String, Selector)]
    private weak var actionTarget: AnyObject?
    private let onToggleHeaders: (Bool) -> Void
    private let onToggleTagged: (Bool) -> Void
    private let onAction: () -> Void

    private var summaryLabel: NSTextField!
    private var headerCheckbox: NSButton!
    private var taggedCheckbox: NSButton?

    init(onSummary: @escaping () -> String, includeHeaders: Bool, taggedOnly: Bool?,
         items: [(String, Selector)], target: AnyObject,
         onToggleHeaders: @escaping (Bool) -> Void,
         onToggleTagged: @escaping (Bool) -> Void,
         onAction: @escaping () -> Void) {
        self.onSummary = onSummary
        self.initialIncludeHeaders = includeHeaders
        self.initialTaggedOnly = taggedOnly
        self.items = items
        self.actionTarget = target
        self.onToggleHeaders = onToggleHeaders
        self.onToggleTagged = onToggleTagged
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()

        // Summary caption: how many columns × rows this action will produce.
        summaryLabel = NSTextField(labelWithString: onSummary())
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        // Header checkbox row
        headerCheckbox = NSButton(checkboxWithTitle: "Include Headers", target: self, action: #selector(headerToggled))
        headerCheckbox.state = initialIncludeHeaders ? .on : .off
        headerCheckbox.font = .systemFont(ofSize: 13)
        headerCheckbox.translatesAutoresizingMaskIntoConstraints = false

        // Tagged-scope checkbox row — only when the grid has a tag map.
        if let initialTaggedOnly {
            let box = NSButton(checkboxWithTitle: "Tagged Rows Only", target: self,
                               action: #selector(taggedToggled))
            box.state = initialTaggedOnly ? .on : .off
            box.font = .systemFont(ofSize: 13)
            box.translatesAutoresizingMaskIntoConstraints = false
            taggedCheckbox = box
        }

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Stack for format buttons
        let buttonStack = NSStackView()
        buttonStack.orientation = .vertical
        buttonStack.alignment = .leading
        buttonStack.spacing = 2
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        for (title, selector) in items {
            let button = createFormatButton(title: title, action: selector)
            buttonStack.addArrangedSubview(button)
            button.leadingAnchor.constraint(equalTo: buttonStack.leadingAnchor).isActive = true
            button.trailingAnchor.constraint(equalTo: buttonStack.trailingAnchor).isActive = true
        }

        // Main vertical stack
        var stackedViews: [NSView] = [summaryLabel, headerCheckbox]
        if let taggedCheckbox { stackedViews.append(taggedCheckbox) }
        stackedViews.append(contentsOf: [separator, buttonStack])
        let mainStack = NSStackView(views: stackedViews)
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 8
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        container.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            separator.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -12),

            buttonStack.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -12),
        ])

        self.view = container
    }

    private func createFormatButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(formatButtonClicked(_:)))
        button.bezelStyle = .recessed
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 13)
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // Store the real selector via tag + associated object
        objc_setAssociatedObject(button, &AssociatedKeys.selectorValue, NSStringFromSelector(action), .OBJC_ASSOCIATION_RETAIN)

        // Hover tracking
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: button, userInfo: nil)
        button.addTrackingArea(area)

        return button
    }

    @objc private func headerToggled() {
        onToggleHeaders(headerCheckbox.state == .on)
    }

    @objc private func taggedToggled() {
        guard let taggedCheckbox else { return }
        onToggleTagged(taggedCheckbox.state == .on)
        // The scope just changed the row count the buttons below would produce.
        summaryLabel.stringValue = onSummary()
    }

    @objc private func formatButtonClicked(_ sender: NSButton) {
        guard let selectorString = objc_getAssociatedObject(sender, &AssociatedKeys.selectorValue) as? String else { return }
        let sel = NSSelectorFromString(selectorString)
        onAction()
        _ = actionTarget?.perform(sel, with: nil)
    }
}

private struct AssociatedKeys {
    static var selectorValue = 0
}
