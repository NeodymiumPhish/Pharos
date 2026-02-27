import AppKit
import UniformTypeIdentifiers

// MARK: - Copy Data

struct CopyData {
    let columnNames: [String]
    let rows: [[String]]
    let includeHeaders: Bool
}

// MARK: - Copy Export Delegate

protocol ResultsCopyExportDelegate: AnyObject {
    func copyExportWindow() -> NSWindow?
}

// MARK: - ResultsCopyExport

class ResultsCopyExport: NSObject, NSMenuDelegate {
    private let tableView: NSTableView
    private let copyButton: NSButton
    private let exportButton: NSButton

    // Data state (pushed by VC)
    var columns: [ColumnDef] = []
    var rows: [[String: AnyCodable]] = []
    var displayRows: [Int] = []
    var columnCategories: [String: PGTypeCategory] = [:]

    /// Cell selection state, pushed by the VC. When set, copy/export uses the cell range.
    var cellSelection: CellSelectionState?

    weak var delegate: ResultsCopyExportDelegate?

    init(tableView: NSTableView, copyButton: NSButton, exportButton: NSButton) {
        self.tableView = tableView
        self.copyButton = copyButton
        self.exportButton = exportButton
        super.init()
    }

    // MARK: - Selection Helper

    private var hasSelection: Bool {
        (cellSelection?.selectedRange != nil) || !tableView.selectedRowIndexes.isEmpty
    }

    // MARK: - Data Gathering

    /// Gathers data from the selected cell range. Returns nil if no cell range is active.
    private func gatherCellRangeData() -> CopyData? {
        guard let selection = cellSelection, let range = selection.selectedRange else { return nil }

        let columns = tableView.tableColumns
        let selectedColIds = (range.topLeft.column...range.bottomRight.column).compactMap { idx -> String? in
            guard idx >= 0, idx < columns.count else { return nil }
            let id = columns[idx].identifier.rawValue
            return id == "__rownum__" ? nil : id
        }
        guard !selectedColIds.isEmpty else { return nil }

        var rowData: [[String]] = []
        for row in range.topLeft.row...range.bottomRight.row {
            guard row >= 0, row < displayRows.count else { continue }
            let dataIdx = displayRows[row]
            guard dataIdx < rows.count else { continue }
            let data = rows[dataIdx]
            let values = selectedColIds.map { data[$0]?.displayString ?? "" }
            rowData.append(values)
        }

        guard !rowData.isEmpty else { return nil }
        return CopyData(columnNames: selectedColIds, rows: rowData, includeHeaders: false)
    }

    /// Gathers data for copy/export. Uses selected rows if any, otherwise all displayed rows.
    func gatherData() -> CopyData? {
        // If a cell range is selected, use that instead of row-based selection
        if let cellRangeData = gatherCellRangeData() {
            return cellRangeData
        }

        let selectedRows = tableView.selectedRowIndexes

        let colIds = tableView.tableColumns.compactMap { col -> String? in
            let id = col.identifier.rawValue
            return id == "__rownum__" ? nil : id
        }
        guard !colIds.isEmpty else { return nil }

        var rowData: [[String]] = []

        if !selectedRows.isEmpty {
            for row in selectedRows {
                guard row < displayRows.count else { continue }
                let data = rows[displayRows[row]]
                let values = colIds.map { data[$0]?.displayString ?? "" }
                rowData.append(values)
            }
        } else {
            for row in 0..<displayRows.count {
                let data = rows[displayRows[row]]
                let values = colIds.map { data[$0]?.displayString ?? "" }
                rowData.append(values)
            }
        }

        guard !rowData.isEmpty else { return nil }
        return CopyData(columnNames: colIds, rows: rowData, includeHeaders: true)
    }

    // MARK: - Copy Support

    @objc func copy(_ sender: Any?) {
        copyAsTSV(sender)
    }

    @objc func copyAsTSV(_: Any?) {
        guard let data = gatherData() else { return }
        var lines = data.rows.map { $0.joined(separator: "\t") }
        if data.includeHeaders {
            lines.insert(data.columnNames.joined(separator: "\t"), at: 0)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc func copyAsCSV(_: Any?) {
        guard let data = gatherData() else { return }
        var lines = data.rows.map { $0.map { Self.csvEscape($0) }.joined(separator: ",") }
        if data.includeHeaders {
            let header = data.columnNames.map { Self.csvEscape($0) }.joined(separator: ",")
            lines.insert(header, at: 0)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc func copyAsMarkdown(_: Any?) {
        guard let data = gatherData() else { return }
        let rows = data.rows.map { "| " + $0.joined(separator: " | ") + " |" }
        let result: String
        if data.includeHeaders {
            let header = "| " + data.columnNames.joined(separator: " | ") + " |"
            let divider = "| " + data.columnNames.map { _ in "---" }.joined(separator: " | ") + " |"
            result = ([header, divider] + rows).joined(separator: "\n")
        } else {
            result = rows.joined(separator: "\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    @objc func copyAsSQLInsert(_: Any?) {
        guard let data = gatherData() else { return }
        let cats = columnCategories
        let colList = data.columnNames.map { "\"\($0)\"" }.joined(separator: ", ")
        let statements = data.rows.map { row in
            let values = zip(data.columnNames, row).map { (col, val) -> String in
                if val.isEmpty || val == "NULL" { return "NULL" }
                let category = cats[col] ?? .string
                switch category {
                case .numeric:
                    return val
                case .boolean:
                    return val
                default:
                    return "'\(val.replacingOccurrences(of: "'", with: "''"))'"
                }
            }
            return "INSERT INTO table_name (\(colList)) VALUES (\(values.joined(separator: ", ")));"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(statements.joined(separator: "\n"), forType: .string)
    }

    static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    // MARK: - Copy Menu

    @objc func showCopyMenu() {
        let prefix = hasSelection ? "Copy selection" : "Copy"
        let menu = NSMenu()
        menu.addItem(withTitle: "\(prefix) as TSV", action: #selector(copyAsTSV), keyEquivalent: "").target = self
        menu.addItem(withTitle: "\(prefix) as CSV", action: #selector(copyAsCSV), keyEquivalent: "").target = self
        menu.addItem(withTitle: "\(prefix) as Markdown", action: #selector(copyAsMarkdown), keyEquivalent: "").target = self
        menu.addItem(withTitle: "\(prefix) as SQL INSERT", action: #selector(copyAsSQLInsert), keyEquivalent: "").target = self
        let point = NSPoint(x: 0, y: 0)
        menu.popUp(positioning: nil, at: point, in: copyButton)
    }

    // MARK: - Export

    @objc func showExportMenu() {
        let prefix = hasSelection ? "Export selection" : "Export"
        let menu = NSMenu()
        menu.addItem(withTitle: "\(prefix) as CSV...", action: #selector(exportAsCSV), keyEquivalent: "").target = self
        menu.addItem(withTitle: "\(prefix) as TSV...", action: #selector(exportAsTSV), keyEquivalent: "").target = self
        menu.addItem(withTitle: "\(prefix) as JSON...", action: #selector(exportAsJSON), keyEquivalent: "").target = self
        menu.addItem(withTitle: "\(prefix) as SQL INSERT...", action: #selector(exportAsSQLInsert), keyEquivalent: "").target = self
        menu.addItem(withTitle: "\(prefix) as Markdown...", action: #selector(exportAsMarkdown), keyEquivalent: "").target = self
        let point = NSPoint(x: 0, y: 0)
        menu.popUp(positioning: nil, at: point, in: exportButton)
    }

    private func exportToFile(filename: String, contentType: UTType, generator: @escaping (CopyData) -> String) {
        guard let data = gatherData(), let window = delegate?.copyExportWindow() else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [contentType]

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let content = generator(data)
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
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
            do {
                let jsonArray = data.rows.map { row in
                    Dictionary(zip(data.columnNames, row), uniquingKeysWith: { _, last in last })
                }
                let jsonData = try JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys])
                try jsonData.write(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func exportAsSQLInsert(_: Any?) {
        let cats = columnCategories
        exportToFile(filename: "export.sql", contentType: UTType(filenameExtension: "sql") ?? .plainText) { data in
            let colList = data.columnNames.map { "\"\($0)\"" }.joined(separator: ", ")
            let statements = data.rows.map { row in
                let values = zip(data.columnNames, row).map { (col, val) -> String in
                    if val.isEmpty || val == "NULL" { return "NULL" }
                    let category = cats[col] ?? .string
                    switch category {
                    case .numeric, .boolean:
                        return val
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

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

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

        return menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let prefix = hasSelection ? "Copy selection" : "Copy"
        for item in menu.items {
            switch item.tag {
            case 1: item.title = "\(prefix) as TSV"
            case 2: item.title = "\(prefix) as CSV"
            case 3: item.title = "\(prefix) as Markdown"
            case 4: item.title = "\(prefix) as SQL INSERT"
            default: break
            }
        }
    }
}
