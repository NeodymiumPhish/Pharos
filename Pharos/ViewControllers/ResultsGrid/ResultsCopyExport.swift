import AppKit
import UniformTypeIdentifiers

// MARK: - Copy Data

struct CopyData {
    let columnNames: [String]
    let columnIndices: [Int]
    let rows: [[String]]
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
    private var includeHeaders = true
    private static let includeHeadersKey = "PharosCopyIncludeHeaders"

    weak var delegate: ResultsCopyExportDelegate?

    init(tableView: NSTableView, copyButton: NSButton, exportButton: NSButton) {
        self.tableView = tableView
        self.copyButton = copyButton
        self.exportButton = exportButton
        self.includeHeaders = UserDefaults.standard.object(forKey: Self.includeHeadersKey) as? Bool ?? true
        super.init()
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

    /// Gathers data from the selected cell range.
    private func gatherCellRangeData() -> CellRangeGather {
        guard let selection = cellSelection, let range = selection.selectedRange else { return .none }

        let tableCols = tableView.tableColumns
        let selectedColIds = (range.topLeft.column...range.bottomRight.column).compactMap { idx -> String? in
            guard idx >= 0, idx < tableCols.count else { return nil }
            let id = tableCols[idx].identifier.rawValue
            return id == "__rownum__" ? nil : id
        }
        guard !selectedColIds.isEmpty else { return .none }

        let resolved = selectedColIds.compactMap { id -> (name: String, index: Int)? in
            guard let idx = colIndex(from: id), idx < self.columns.count else { return nil }
            return (self.columns[idx].name, idx)
        }
        let displayNames = resolved.map(\.name)
        let indices = resolved.map(\.index)

        var rowData: [[String]] = []
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
                idx < data.count ? data[idx].displayString : ""
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
            let id = col.identifier.rawValue
            return id == "__rownum__" ? nil : id
        }
        guard !colIds.isEmpty else { return nil }

        let resolved = colIds.compactMap { id -> (name: String, index: Int)? in
            guard let idx = colIndex(from: id), idx < self.columns.count else { return nil }
            return (self.columns[idx].name, idx)
        }
        let displayNames = resolved.map(\.name)
        let indices = resolved.map(\.index)

        var rowData: [[String]] = []

        if !selectedRows.isEmpty {
            for row in selectedRows {
                guard row < displayRows.count,
                      TagCopyScope.include(dataRow: displayRows[row], taggedOnly: taggedOnly,
                                           taggedRows: taggedRows) else { continue }
                let data = rows[displayRows[row]]
                let values = indices.map { idx in
                    idx < data.count ? data[idx].displayString : ""
                }
                rowData.append(values)
            }
        } else {
            for row in 0..<displayRows.count {
                guard TagCopyScope.include(dataRow: displayRows[row], taggedOnly: taggedOnly,
                                           taggedRows: taggedRows) else { continue }
                let data = rows[displayRows[row]]
                let values = indices.map { idx in
                    idx < data.count ? data[idx].displayString : ""
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
                guard idx >= 0, idx < tableCols.count else { return nil }
                let id = tableCols[idx].identifier.rawValue
                return id == "__rownum__" ? nil : id
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
            let id = col.identifier.rawValue
            guard id != "__rownum__", let idx = colIndex(from: id) else { return false }
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
        copyAsTSV(sender)
    }

    /// Format a CopyData payload off the main thread, then set the pasteboard on main.
    /// For large selections (10k+ rows) the join/escape/SQL build was the longest
    /// main-thread block in the app; this keeps the UI responsive during copies.
    private func copyOnBackground(_ format: @escaping (CopyData) -> String) {
        guard let data = gatherData() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let text = format(data)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    @objc func copyAsTSV(_: Any?) {
        copyOnBackground { data in
            var lines = data.rows.map { $0.joined(separator: "\t") }
            if data.includeHeaders {
                lines.insert(data.columnNames.joined(separator: "\t"), at: 0)
            }
            return lines.joined(separator: "\n")
        }
    }

    @objc func copyAsCSV(_: Any?) {
        copyOnBackground { data in
            var lines = data.rows.map { $0.map { Self.csvEscape($0) }.joined(separator: ",") }
            if data.includeHeaders {
                let header = data.columnNames.map { Self.csvEscape($0) }.joined(separator: ",")
                lines.insert(header, at: 0)
            }
            return lines.joined(separator: "\n")
        }
    }

    @objc func copyAsMarkdown(_: Any?) {
        copyOnBackground { data in
            let rows = data.rows.map { "| " + $0.joined(separator: " | ") + " |" }
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
            let colList = data.columnNames.map { "\"\($0)\"" }.joined(separator: ", ")
            let statements = data.rows.map { row in
                let values = zip(data.columnIndices, row).map { (colIdx, val) -> String in
                    if val.isEmpty || val == "NULL" { return "NULL" }
                    let category = colIdx < cats.count ? cats[colIdx] : .string
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
    }

    @objc func copyAsSQLWith(_: Any?) {
        let cats = columnCategories
        let cols = columns
        copyOnBackground { data in
            // copyAsSQLWith historically suppressed headers regardless of the
            // user toggle (the WITH/cte() carries column names already), so
            // preserve that behavior here in the off-thread path.
            let _ = data.includeHeaders

            let colList = data.columnNames.joined(separator: ", ")
            let valueRows = data.rows.enumerated().map { (rowIdx, row) in
                let values = zip(data.columnIndices, row).map { (colIdx, val) -> String in
                    let pgType = colIdx < cols.count ? cols[colIdx].dataType : "text"
                    // NULLs in row 0 still need the type cast — otherwise PG has
                    // nothing to anchor type inference on for that column and
                    // mixed-type unification across rows can fail downstream.
                    if val.isEmpty || val == "NULL" {
                        return rowIdx == 0 ? "NULL::\(pgType)" : "NULL"
                    }
                    let category = colIdx < cats.count ? cats[colIdx] : .string
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
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            // RFC 4180 CSV quoting doubles embedded quotes. This shares the
            // mechanic with SQL identifier quoting but is a separate domain:
            // exported bytes must stay exact, so it keeps its own quoting and
            // must not track changes to the SQL quoter.
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
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
        ]
        showPopover(from: exportButton, items: items)
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
                UserDefaults.standard.set(newValue, forKey: Self.includeHeadersKey)
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
            var lines = data.rows.map { $0.map { Self.csvEscape($0) }.joined(separator: ",") }
            if data.includeHeaders {
                let header = data.columnNames.map { Self.csvEscape($0) }.joined(separator: ",")
                lines.insert(header, at: 0)
            }
            return lines.joined(separator: "\n")
        }
    }

    @objc private func exportAsTSV(_: Any?) {
        exportToFile(filename: "export.tsv", contentType: .tabSeparatedText) { data in
            var lines = data.rows.map { $0.joined(separator: "\t") }
            if data.includeHeaders {
                lines.insert(data.columnNames.joined(separator: "\t"), at: 0)
            }
            return lines.joined(separator: "\n")
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
                    let jsonArray = data.rows.map { row in
                        Dictionary(zip(data.columnNames, row), uniquingKeysWith: { _, last in last })
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
        let cats = columnCategories
        exportToFile(filename: "export.sql", contentType: UTType(filenameExtension: "sql") ?? .plainText) { data in
            let colList = data.columnNames.map { "\"\($0)\"" }.joined(separator: ", ")
            let statements = data.rows.map { row in
                let values = zip(data.columnIndices, row).map { (colIdx, val) -> String in
                    if val.isEmpty || val == "NULL" { return "NULL" }
                    let category = colIdx < cats.count ? cats[colIdx] : .string
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
    }

    @objc private func exportAsMarkdown(_: Any?) {
        exportToFile(filename: "export.md", contentType: UTType(filenameExtension: "md") ?? .plainText) { data in
            let rows = data.rows.map { "| " + $0.joined(separator: " | ") + " |" }
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
        UserDefaults.standard.set(includeHeaders, forKey: Self.includeHeadersKey)
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
