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
        return CopyData(columnNames: colIds, rows: rowData, includeHeaders: includeHeaders)
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

    private func showPopover(from button: NSButton, items: [(String, Selector)]) {
        let vc = CopyExportPopoverVC(
            includeHeaders: includeHeaders,
            items: items,
            target: self,
            onToggleHeaders: { [weak self] newValue in
                guard let self else { return }
                self.includeHeaders = newValue
                UserDefaults.standard.set(newValue, forKey: Self.includeHeadersKey)
            },
            onAction: { [weak self] in
                self?.activePopover?.close()
                self?.activePopover = nil
            }
        )

        let popover = NSPopover()
        popover.contentViewController = vc
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

    @objc private func toggleIncludeHeaders() {
        includeHeaders.toggle()
        UserDefaults.standard.set(includeHeaders, forKey: Self.includeHeadersKey)
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let headers = menu.addItem(withTitle: "Include Headers", action: #selector(toggleIncludeHeaders), keyEquivalent: "")
        headers.tag = 10
        headers.target = self

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
            case 10: item.state = includeHeaders ? .on : .off
            default: break
            }
        }
    }
}

// MARK: - Copy/Export Popover VC

/// Popover view controller that shows an "Include Headers" checkbox
/// and a list of format buttons, styled like Xcode's debug area popovers.
class CopyExportPopoverVC: NSViewController {

    private let initialIncludeHeaders: Bool
    private let items: [(String, Selector)]
    private weak var actionTarget: AnyObject?
    private let onToggleHeaders: (Bool) -> Void
    private let onAction: () -> Void

    private var headerCheckbox: NSButton!

    init(includeHeaders: Bool, items: [(String, Selector)], target: AnyObject,
         onToggleHeaders: @escaping (Bool) -> Void, onAction: @escaping () -> Void) {
        self.initialIncludeHeaders = includeHeaders
        self.items = items
        self.actionTarget = target
        self.onToggleHeaders = onToggleHeaders
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()

        // Header checkbox row
        headerCheckbox = NSButton(checkboxWithTitle: "Include Headers", target: self, action: #selector(headerToggled))
        headerCheckbox.state = initialIncludeHeaders ? .on : .off
        headerCheckbox.font = .systemFont(ofSize: 13)
        headerCheckbox.translatesAutoresizingMaskIntoConstraints = false

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
        let mainStack = NSStackView(views: [headerCheckbox, separator, buttonStack])
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
